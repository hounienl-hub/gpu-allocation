# Quick Start Guide

## Complete Deployment in 3 Commands

### 1. Setup the Cluster

```bash
chmod +x setup-cluster.sh configure-mig-profiles.sh
./setup-cluster.sh
```

**What this does:**
- Creates a Kind cluster with 6 worker nodes (3 small, 3 medium)
- Installs fake-gpu-operator via Helm
- Configures MIG profiles on all nodes
- Labels nodes for GPU simulation

**Expected output:**
```
Cluster setup complete!

Summary:
- Small nodes (3): 4 GPUs each, 7x 1g.10gb MIGs per GPU = 28 MIG devices per node
- Medium nodes (3): 4 GPUs each, (3x 2g.20gb + 1x 1g.10gb) MIGs per GPU = 16 MIG devices per node
```

### 2. Deploy the Webhook

```bash
cd webhook
chmod +x build-and-deploy.sh generate-certs.sh init-go-module.sh
./init-go-module.sh  # Initialize Go dependencies
./build-and-deploy.sh
cd ..
```

**What this does:**
- Builds the webhook container image
- Generates TLS certificates
- Deploys webhook to the cluster
- Configures MutatingWebhookConfiguration

**Expected output:**
```
Webhook deployed successfully!

Verify webhook is running:
kubectl get pods -n gpu-webhook
```

### 3. Test the Setup

```bash
# Test a pod that requests 2g.20gb (will fallback to 1g.10gb if unavailable)
kubectl apply -f test-pods/test-medium-gpu.yaml

# Check if webhook modified the request
kubectl get pod test-medium-gpu -o jsonpath='{.metadata.annotations}' | jq
kubectl describe pod test-medium-gpu | grep -A10 "Requests:"
```

**Expected result:**
- Pod will be created with GPU resources
- If 2g.20gb is unavailable, annotation will show: `"gpu-webhook.k8s.io/fallback": "2g.20gb->1g.10gb"`
- Pod will use 1g.10gb MIG instead

## Verify Everything is Working

```bash
# 1. Check nodes have GPU resources
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
POOL:.metadata.labels.node-pool,\
MIG-1g:.status.capacity.nvidia\\.com/mig-1g\\.10gb,\
MIG-2g:.status.capacity.nvidia\\.com/mig-2g\\.20gb

# 2. Check webhook is healthy
kubectl get pods -n gpu-webhook
kubectl logs -n gpu-webhook -l app=gpu-webhook --tail=20

# 3. Create a test deployment
kubectl apply -f test-pods/test-deployment.yaml
kubectl get pods -l app=gpu-test

# 4. Check which pods had GPU fallback applied
kubectl get pods -l app=gpu-test -o custom-columns=\
NAME:.metadata.name,\
FALLBACK:.metadata.annotations.gpu-webhook\\.k8s\\.io/fallback
```

## Common Issues

### Issue: Webhook pod not starting

```bash
# Check webhook logs
kubectl logs -n gpu-webhook -l app=gpu-webhook

# Check certificate secret exists
kubectl get secret gpu-webhook-certs -n gpu-webhook

# Regenerate certificates if needed
cd webhook
./generate-certs.sh
kubectl rollout restart deployment/gpu-webhook -n gpu-webhook
cd ..
```

### Issue: MIG resources not showing on nodes

```bash
# Check fake-gpu-operator is running
kubectl get pods -n gpu-operator

# Check node labels
kubectl get nodes --show-labels | grep "mig"

# Reapply MIG configuration
./configure-mig-profiles.sh
```

### Issue: Pods not being intercepted by webhook

```bash
# Check webhook configuration
kubectl get mutatingwebhookconfiguration gpu-allocation-webhook

# Verify webhook service is accessible
kubectl get svc -n gpu-webhook
kubectl get endpoints -n gpu-webhook

# Check webhook logs for incoming requests
kubectl logs -n gpu-webhook -l app=gpu-webhook -f
```

## Next Steps

1. **Monitor webhook decisions**: `kubectl logs -n gpu-webhook -l app=gpu-webhook -f`
2. **Create realistic workloads**: Modify test manifests in `test-pods/`
3. **Experiment with GPU exhaustion**: Deploy many pods to see fallback in action
4. **Extend webhook logic**: Edit `webhook/main.go` to add custom rules

## Cleanup

```bash
# Remove test workloads
kubectl delete -f test-pods/ --ignore-not-found

# Delete entire cluster
kind delete cluster --name gpu-sim-cluster
```

## Resource Summary

After setup, you'll have:

| Node Type | Count | GPUs/Node | MIG Profile | Total MIG Devices |
|-----------|-------|-----------|-------------|-------------------|
| Small     | 3     | 4         | 7× 1g.10gb  | 84× 1g.10gb       |
| Medium    | 3     | 4         | 3× 2g.20gb + 1× 1g.10gb | 36× 2g.20gb + 12× 1g.10gb |

**Total Capacity:**
- 96× 1g.10gb MIG devices (84 from small + 12 from medium)
- 36× 2g.20gb MIG devices (all from medium)

The webhook ensures optimal GPU utilization by automatically falling back to available resources!
