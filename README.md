# GPU Allocation Simulation with Kind and Fake GPU Operator

This project simulates GPU allocation in Kubernetes using a local Kind cluster and the fake-gpu-operator. It includes an intelligent admission webhook that automatically falls back to smaller GPU MIG profiles when requested sizes are unavailable.

## Architecture

### Node Configuration

Both nodes use identical hardware (NVIDIA H200 70GB with 4 cards), but different MIG configurations:

#### Small Node (1 node)
- **Hardware**: 4× NVIDIA H200 cards (7g.70gb each)
- **MIG Profile**: 7× 1g.10gb per card
- **Total MIG devices**: 28× 1g.10gb

#### Medium Node (1 node)
- **Hardware**: 4× NVIDIA H200 cards (7g.70gb each)
- **MIG Profile**: 3× 2g.20gb + 1× 1g.10gb per card
- **Total MIG devices**: 12× 2g.20gb + 4× 1g.10gb

### Total Cluster Capacity
- **32× 1g.10gb** MIG devices
- **12× 2g.20gb** MIG devices

### Intelligent GPU Allocation Webhook

The admission webhook intercepts Pod, Job, and Deployment creation requests and:

1. **Monitors GPU resource requests** for `nvidia.com/mig-2g.20gb`
2. **Checks availability** across all nodes
3. **Automatically falls back** to `nvidia.com/mig-1g.10gb` if 2g.20gb is not available
4. **Adds annotation** to pods indicating the fallback occurred

**Key benefit**: Users don't need to modify their YAML or resubmit requests when their preferred GPU size is unavailable.

## Prerequisites

- Docker
- Kind
- kubectl
- Helm 3.x
- OpenSSL (for webhook certificate generation)

## Quick Start

### 1. Deploy the Complete Stack

```bash
# Using Make (recommended)
make setup

# Or manually:
chmod +x scripts/setup-cluster.sh scripts/configure-mig-profiles.sh
./scripts/setup-cluster.sh
```

This will:
- Create a Kind cluster with 2 worker nodes (1 small, 1 medium)
- Install fake-gpu-operator
- Configure MIG profiles on both nodes
- Label nodes appropriately

### 2. Build and Deploy the Webhook

```bash
# Using Make (recommended)
make deploy-webhook

# Or manually:
cd webhook
chmod +x scripts/*.sh
./scripts/init-go-module.sh
./scripts/build-and-deploy.sh
cd ..
```

This will:
- Build the webhook Docker image
- Load it into the Kind cluster
- Generate TLS certificates
- Deploy the webhook components
- Configure the MutatingWebhookConfiguration

### 3. Verify the Setup

```bash
# Check nodes and their GPU resources
kubectl get nodes --show-labels

# View MIG resources on nodes
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
MIG-1g.10gb:.status.capacity.nvidia\\.com/mig-1g\\.10gb,\
MIG-2g.20gb:.status.capacity.nvidia\\.com/mig-2g\\.20gb

# Check webhook is running
kubectl get pods -n gpu-webhook
```

## Testing

### Test Pod with Medium GPU Request

```bash
# Deploy a pod requesting 2g.20gb MIG
kubectl apply -f manifests/test-pods/test-medium-gpu.yaml

# Check if webhook modified the request
kubectl get pod test-medium-gpu -o yaml | grep -A5 annotations
kubectl get pod test-medium-gpu -o yaml | grep -A5 resources
```

If no 2g.20gb MIGs are available, the webhook will:
- Change the request from `nvidia.com/mig-2g.20gb: 1` to `nvidia.com/mig-1g.10gb: 1`
- Add annotation: `gpu-webhook.k8s.io/fallback: "2g.20gb->1g.10gb"`

### Test with Deployment

```bash
# Deploy multiple replicas requesting medium GPUs
kubectl apply -f manifests/test-pods/test-deployment.yaml

# Watch pods being scheduled
kubectl get pods -l app=gpu-test -w

# Check which pods were modified by the webhook
kubectl get pods -l app=gpu-test -o custom-columns=\
NAME:.metadata.name,\
FALLBACK:.metadata.annotations.gpu-webhook\\.k8s\\.io/fallback,\
GPU-REQUEST:.spec.containers[0].resources.requests
```

### Test with Job

```bash
# Create a job with GPU requirement
kubectl apply -f manifests/test-pods/test-job.yaml

# Check job status
kubectl get jobs
kubectl logs job/test-gpu-job
```

## Webhook Behavior

### Fallback Logic

1. **Pod requests**: `nvidia.com/mig-2g.20gb: 1`
2. **Webhook checks**: Are any 2g.20gb MIGs available on any node?
3. **If unavailable**:
   - Modifies request to: `nvidia.com/mig-1g.10gb: 1`
   - Adds annotation: `gpu-webhook.k8s.io/fallback: "2g.20gb->1g.10gb"`
4. **If available**: No modification, pod scheduled normally

### Logs

```bash
# View webhook logs to see decisions
kubectl logs -n gpu-webhook -l app=gpu-webhook -f
```

Expected log output:
```
Reviewing pod: default/test-medium-gpu
Pod default/test-medium-gpu requests 2g.20gb MIG
2g.20gb not available, falling back to 1g.10gb for pod default/test-medium-gpu
Applied fallback patch to pod default/test-medium-gpu
```

## MIG Profile Details

### H200 70GB MIG Profiles

The NVIDIA H200 with 70GB memory supports various MIG profiles:

- **1g.10gb**: 1 GPU slice, ~10GB memory (7 instances max per GPU)
- **2g.20gb**: 2 GPU slices, ~20GB memory (3 instances max per GPU)
- **3g.40gb**: 3 GPU slices, ~40GB memory (2 instances max per GPU)
- **7g.70gb**: Full GPU, ~70GB memory (1 instance per GPU)

### Current Configuration

**Small Node**: Maximizes small MIG instances
- 4× H200 cards × 7 instances each = 28× 1g.10gb MIG devices

**Medium Node**: Mixed profile for larger workloads with fallback option
- 4× H200 cards × (3× 2g.20gb + 1× 1g.10gb) each = 12× 2g.20gb + 4× 1g.10gb MIG devices

**Total Cluster**: 32× 1g.10gb + 12× 2g.20gb MIG devices

This configuration allows testing the webhook's intelligent fallback behavior when 2g.20gb resources on the medium node become exhausted - pods automatically get scheduled with 1g.10gb resources instead.

## Troubleshooting

### Webhook not intercepting pods

```bash
# Check webhook configuration
kubectl get mutatingwebhookconfiguration gpu-allocation-webhook -o yaml

# Verify CA bundle is set
kubectl get mutatingwebhookconfiguration gpu-allocation-webhook \
  -o jsonpath='{.webhooks[0].clientConfig.caBundle}' | base64 -d

# Check webhook service endpoints
kubectl get endpoints -n gpu-webhook
```

### MIG profiles not showing

```bash
# Check node annotations
kubectl get nodes -o yaml | grep -A20 "run.ai/mig.config"

# Verify fake-gpu-operator is running
kubectl get pods -n gpu-operator

# Check fake-gpu-operator logs
kubectl logs -n gpu-operator -l app.kubernetes.io/name=fake-gpu-operator
```

### Certificate issues

```bash
# Regenerate certificates
cd webhook
./scripts/generate-certs.sh

# Reapply webhook config
kubectl apply -f deploy/04-webhook-config-patched.yaml

# Restart webhook pods
kubectl rollout restart deployment/gpu-webhook -n gpu-webhook
cd ..
```

## Cleanup

```bash
# Delete test workloads
kubectl delete -f manifests/test-pods/

# Delete webhook
kubectl delete -f webhook/deploy/

# Delete cluster
kind delete cluster --name gpu-sim-cluster
```

## Architecture Diagram

```
┌─────────────────────────────────────────────────────────────┐
│                     Kind Cluster                             │
├─────────────────────────────────────────────────────────────┤
│                                                               │
│  ┌──────────────────────┐  ┌──────────────────────┐        │
│  │   Small Worker Node   │  │  Medium Worker Node  │        │
│  │ 4× H200 (7g.70gb)     │  │ 4× H200 (7g.70gb)    │        │
│  │                       │  │                      │        │
│  │ All 4 cards:          │  │ All 4 cards:         │        │
│  │ 7× 1g.10gb each       │  │ 3× 2g.20gb +         │        │
│  │                       │  │ 1× 1g.10gb each      │        │
│  │                       │  │                      │        │
│  │ Total: 28× 1g.10gb    │  │ Total: 12× 2g.20gb + │        │
│  │                       │  │        4× 1g.10gb    │        │
│  └──────────────────────┘  └──────────────────────┘        │
│                                                               │
│  ┌─────────────────────────────────────────────────┐        │
│  │        GPU Allocation Webhook                    │        │
│  │  • Intercepts Pod/Job/Deployment creation       │        │
│  │  • Checks 2g.20gb availability                  │        │
│  │  • Falls back to 1g.10gb if needed              │        │
│  │  • Adds annotation for transparency             │        │
│  └─────────────────────────────────────────────────┘        │
│                                                               │
│  ┌─────────────────────────────────────────────────┐        │
│  │          Fake GPU Operator                       │        │
│  │  • Simulates NVIDIA GPU resources                │        │
│  │  • Manages MIG device allocation                │        │
│  │  • Provides nvidia-smi simulation               │        │
│  └─────────────────────────────────────────────────┘        │
│                                                               │
└─────────────────────────────────────────────────────────────┘
```

## Extending the Setup

### Add Large Node Pool

To add a large node pool with full 7g.70gb MIGs:

1. Add nodes to `config/kind-gpu-cluster.yaml`:
   ```yaml
   - role: worker
     labels:
       node-pool: large
   ```

2. Add to `config/fake-gpu-values.yaml`:
   ```yaml
   large:
     gpuProduct: NVIDIA-H200
     gpuCount: 4
     gpuMemory: 71680
   ```

3. Configure MIG profile in a new script or extend `scripts/configure-mig-profiles.sh`

### Customize Webhook Logic

Edit `webhook/cmd/main.go` to:
- Add support for other MIG sizes (3g.40gb, 7g.80gb)
- Implement multi-tier fallback (2g → 1g → fail)
- Add custom scheduling hints based on node labels
- Implement GPU affinity rules

## References

- [fake-gpu-operator GitHub](https://github.com/run-ai/fake-gpu-operator)
- [NVIDIA MIG User Guide](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/)
- [Kubernetes Admission Webhooks](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/)
- [Kind Documentation](https://kind.sigs.k8s.io/)
