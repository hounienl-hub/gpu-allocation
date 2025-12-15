package main

import (
	"context"
	"encoding/json"
	"fmt"
	"io"
	"net/http"
	"os"

	admissionv1 "k8s.io/api/admission/v1"
	corev1 "k8s.io/api/core/v1"
	"k8s.io/apimachinery/pkg/api/resource"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	"k8s.io/apimachinery/pkg/runtime/serializer"
	"k8s.io/client-go/kubernetes"
	"k8s.io/client-go/rest"
	"k8s.io/klog/v2"
)

var (
	scheme = runtime.NewScheme()
	codecs = serializer.NewCodecFactory(scheme)
)

type GPUAllocationWebhook struct {
	clientset *kubernetes.Clientset
}

func NewGPUAllocationWebhook() (*GPUAllocationWebhook, error) {
	config, err := rest.InClusterConfig()
	if err != nil {
		return nil, err
	}

	clientset, err := kubernetes.NewForConfig(config)
	if err != nil {
		return nil, err
	}

	return &GPUAllocationWebhook{
		clientset: clientset,
	}, nil
}

func (w *GPUAllocationWebhook) handleMutate(ar admissionv1.AdmissionReview) *admissionv1.AdmissionResponse {
	req := ar.Request
	var pod corev1.Pod

	if err := json.Unmarshal(req.Object.Raw, &pod); err != nil {
		klog.Errorf("Could not unmarshal pod: %v", err)
		return &admissionv1.AdmissionResponse{
			Result: &metav1.Status{
				Message: err.Error(),
			},
		}
	}

	klog.Infof("Reviewing pod: %s/%s", pod.Namespace, pod.Name)

	// Check if pod has GPU resource requests
	patches := []map[string]interface{}{}
	modified := false

	for containerIdx, container := range pod.Spec.Containers {
		if container.Resources.Requests == nil {
			continue
		}

		// Check for medium GPU request (2g.20gb)
		if qty, exists := container.Resources.Requests["nvidia.com/mig-2g.20gb"]; exists && !qty.IsZero() {
			klog.Infof("Pod %s/%s requests 2g.20gb MIG", pod.Namespace, pod.Name)

			// Check if 2g.20gb is available across medium nodes
			available, err := w.checkMIGAvailability("nvidia.com/mig-2g.20gb")
			if err != nil {
				klog.Errorf("Error checking MIG availability: %v", err)
			}

			if !available {
				// Check if 1g.10gb is available
				fallback1g, _ := w.checkMIGAvailability("nvidia.com/mig-1g.10gb")

				// Determine fallback target
				fallbackResource := "nvidia.com/mig-1g.10gb"
				fallbackLabel := "2g.20gb->1g.10gb"

				if !fallback1g {
					// Fall back to basic GPU if MIG not available
					fallbackResource = "nvidia.com/gpu"
					fallbackLabel = "2g.20gb->gpu"
					klog.Infof("2g.20gb and 1g.10gb not available, falling back to basic GPU for pod %s/%s", pod.Namespace, pod.Name)
				} else {
					klog.Infof("2g.20gb not available, falling back to 1g.10gb for pod %s/%s", pod.Namespace, pod.Name)
				}

				// Create patch to replace 2g.20gb with fallback resource
				// Escape "/" in resource names for JSON patch
				escapedFallback := fallbackResource
				if fallbackResource == "nvidia.com/gpu" {
					escapedFallback = "nvidia.com~1gpu"
				} else if fallbackResource == "nvidia.com/mig-1g.10gb" {
					escapedFallback = "nvidia.com~1mig-1g.10gb"
				}

				patches = append(patches, map[string]interface{}{
					"op":    "remove",
					"path":  fmt.Sprintf("/spec/containers/%d/resources/requests/nvidia.com~1mig-2g.20gb", containerIdx),
				})
				patches = append(patches, map[string]interface{}{
					"op":    "add",
					"path":  fmt.Sprintf("/spec/containers/%d/resources/requests/%s", containerIdx, escapedFallback),
					"value": qty.String(),
				})

				// Also patch limits if they exist
				if container.Resources.Limits != nil {
					if limitQty, limitExists := container.Resources.Limits["nvidia.com/mig-2g.20gb"]; limitExists {
						patches = append(patches, map[string]interface{}{
							"op":   "remove",
							"path": fmt.Sprintf("/spec/containers/%d/resources/limits/nvidia.com~1mig-2g.20gb", containerIdx),
						})
						patches = append(patches, map[string]interface{}{
							"op":    "add",
							"path":  fmt.Sprintf("/spec/containers/%d/resources/limits/%s", containerIdx, escapedFallback),
							"value": limitQty.String(),
						})
					}
				}

				// Add annotation to indicate the fallback occurred
				if pod.Annotations == nil {
					patches = append(patches, map[string]interface{}{
						"op":    "add",
						"path":  "/metadata/annotations",
						"value": map[string]string{},
					})
				}
				patches = append(patches, map[string]interface{}{
					"op":    "add",
					"path":  "/metadata/annotations/gpu-webhook.k8s.io~1fallback",
					"value": fallbackLabel,
				})

				modified = true
			}
		}
	}

	response := &admissionv1.AdmissionResponse{
		Allowed: true,
		UID:     req.UID,
	}

	if modified {
		patchBytes, err := json.Marshal(patches)
		if err != nil {
			klog.Errorf("Could not marshal patches: %v", err)
			return &admissionv1.AdmissionResponse{
				Result: &metav1.Status{
					Message: err.Error(),
				},
			}
		}

		patchType := admissionv1.PatchTypeJSONPatch
		response.Patch = patchBytes
		response.PatchType = &patchType
		klog.Infof("Applied fallback patch to pod %s/%s", pod.Namespace, pod.Name)
	}

	return response
}

func (w *GPUAllocationWebhook) checkMIGAvailability(resourceName string) (bool, error) {
	nodes, err := w.clientset.CoreV1().Nodes().List(context.Background(), metav1.ListOptions{})
	if err != nil {
		return false, err
	}

	for _, node := range nodes.Items {
		if allocatable, exists := node.Status.Allocatable[corev1.ResourceName(resourceName)]; exists {
			if allocatable.Cmp(resource.MustParse("1")) >= 0 {
				return true, nil
			}
		}
	}

	return false, nil
}

func (wh *GPUAllocationWebhook) serve(w http.ResponseWriter, r *http.Request) {
	var body []byte
	if r.Body != nil {
		if data, err := io.ReadAll(r.Body); err == nil {
			body = data
		}
	}

	contentType := r.Header.Get("Content-Type")
	if contentType != "application/json" {
		klog.Errorf("contentType=%s, expect application/json", contentType)
		return
	}

	var reviewResponse *admissionv1.AdmissionResponse
	ar := admissionv1.AdmissionReview{}
	deserializer := codecs.UniversalDeserializer()
	if _, _, err := deserializer.Decode(body, nil, &ar); err != nil {
		klog.Errorf("Can't decode body: %v", err)
		reviewResponse = &admissionv1.AdmissionResponse{
			Result: &metav1.Status{
				Message: err.Error(),
			},
		}
	} else {
		reviewResponse = wh.handleMutate(ar)
	}

	response := admissionv1.AdmissionReview{
		TypeMeta: metav1.TypeMeta{
			APIVersion: "admission.k8s.io/v1",
			Kind:       "AdmissionReview",
		},
	}
	if reviewResponse != nil {
		response.Response = reviewResponse
	}

	resp, err := json.Marshal(response)
	if err != nil {
		klog.Errorf("Can't encode response: %v", err)
		http.Error(w, fmt.Sprintf("could not encode response: %v", err), http.StatusInternalServerError)
	}
	if _, err := w.Write(resp); err != nil {
		klog.Errorf("Can't write response: %v", err)
		http.Error(w, fmt.Sprintf("could not write response: %v", err), http.StatusInternalServerError)
	}
}

func main() {
	webhook, err := NewGPUAllocationWebhook()
	if err != nil {
		klog.Fatalf("Failed to create webhook: %v", err)
	}

	http.HandleFunc("/mutate", func(w http.ResponseWriter, r *http.Request) {
		webhook.serve(w, r)
	})

	http.HandleFunc("/healthz", func(w http.ResponseWriter, r *http.Request) {
		w.WriteHeader(http.StatusOK)
		w.Write([]byte("ok"))
	})

	port := os.Getenv("PORT")
	if port == "" {
		port = "8443"
	}

	klog.Infof("Starting GPU allocation webhook server on port %s", port)
	server := &http.Server{
		Addr:      fmt.Sprintf(":%s", port),
		TLSConfig: nil,
	}

	if err := server.ListenAndServeTLS("/etc/webhook/certs/tls.crt", "/etc/webhook/certs/tls.key"); err != nil {
		klog.Fatalf("Failed to start server: %v", err)
	}
}
