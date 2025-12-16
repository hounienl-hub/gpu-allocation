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

## Using Make

This project includes a Makefile for streamlined operations. All commands should be run from the project root directory.

### Available Make Targets

View all available commands:
```bash
make help
```

**Output:**
```
Available targets:
  all                   Complete setup and deployment
  clean                 Delete the entire cluster
  clean-workloads       Delete test workloads
  deploy-webhook        Build and deploy the GPU allocation webhook
  logs-operator         View fake-gpu-operator logs
  logs-webhook          View webhook logs
  setup                 Setup the Kind cluster with fake-gpu-operator
  test                  Deploy test workloads
  verify                Verify the setup
```

### Common Workflows

**1. Complete Setup (First Time)**
```bash
make all        # setup + deploy-webhook + verify
```

**2. Development Workflow**
```bash
make setup             # Create cluster
make deploy-webhook    # Build and deploy webhook
make verify            # Check everything is running
make test              # Deploy test pods
make logs-webhook      # Watch webhook logs
```

**3. Testing Workflow**
```bash
make test              # Deploy test pods
make logs-webhook      # Watch webhook decisions
make clean-workloads   # Clean up test pods
```

**4. Complete Cleanup**
```bash
make clean-workloads   # Delete test pods first
make clean             # Delete entire cluster
```

### Make Target Details

| Target | Description | What it does |
|--------|-------------|--------------|
| `make setup` | Create and configure cluster | Creates Kind cluster, installs fake-gpu-operator, configures MIG profiles |
| `make deploy-webhook` | Deploy webhook | Builds Docker image, generates certificates, deploys webhook to cluster |
| `make verify` | Verify installation | Shows node status, GPU resources, operator pods, webhook pods |
| `make test` | Run test workloads | Deploys test pods and shows their status |
| `make logs-webhook` | Stream webhook logs | Follows webhook logs in real-time (Ctrl+C to exit) |
| `make logs-operator` | Stream operator logs | Follows fake-gpu-operator logs in real-time |
| `make clean-workloads` | Delete test pods | Removes all test workloads |
| `make clean` | Delete cluster | Completely removes the Kind cluster |
| `make all` | Complete setup | Runs setup + deploy-webhook + verify |

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

This project includes comprehensive test cases to validate webhook functionality across different scenarios.

### Quick Test (Using Make)

```bash
# Deploy test workloads
make test

# Watch webhook logs
make logs-webhook

# Clean up
make clean-workloads
```

### Test Cases

#### Test 1: Single Pod with 2g.20gb MIG Request

**What it tests**: Basic fallback when 2g.20gb is unavailable

```bash
# Deploy test pod
kubectl apply -f manifests/test-pods/test-medium-gpu.yaml

# Check webhook modification
kubectl get pod test-medium-gpu -o jsonpath='{.metadata.annotations.gpu-webhook\.k8s\.io/fallback}'
# Expected output: "2g.20gb->gpu" or "2g.20gb->1g.10gb"

# Check actual resource assigned
kubectl get pod test-medium-gpu -o jsonpath='{.spec.containers[0].resources.requests}'
# Expected output: {"nvidia.com/gpu":"1"} or {"nvidia.com/mig-1g.10gb":"1"}

# View webhook decision logs
kubectl logs -n gpu-webhook -l app=gpu-webhook --tail=20
```

#### Test 2: Multiple Pods with Deployment

**What it tests**: Webhook handles multiple pods consistently

```bash
# Deploy 5 replicas
kubectl apply -f manifests/test-pods/test-deployment.yaml

# Watch pods being scheduled
kubectl get pods -l app=gpu-test -w

# Check fallback decisions for all pods
kubectl get pods -l app=gpu-test -o custom-columns=\
NAME:.metadata.name,\
STATUS:.status.phase,\
FALLBACK:.metadata.annotations.gpu-webhook\\.k8s\\.io/fallback

# View resource distribution
kubectl get pods -l app=gpu-test -o json | \
  jq -r '.items[] | "\(.metadata.name): \(.spec.containers[0].resources.requests)"'
```

#### Test 3: Large GPU (3g.30gb) with Multi-tier Fallback

**What it tests**: Full fallback chain (3g.30gb → 2g.20gb → 1g.10gb → gpu)

```bash
# Deploy pods requesting 3g.30gb
kubectl apply -f manifests/test-pods/test-large-gpu.yaml

# Check fallback annotations
kubectl get pods -l app=gpu-test-large -o jsonpath='{range .items[*]}{.metadata.name}{"\t"}{.metadata.annotations.gpu-webhook\.k8s\.io/fallback}{"\n"}{end}'
# Expected output: test-large-gpu	3g.30gb->2g.20gb (or ->1g.10gb or ->gpu)

# View webhook decision process
kubectl logs -n gpu-webhook -l app=gpu-webhook | grep "3g.30gb"
```

#### Test 4: Resource Exhaustion Test

**What it tests**: Webhook behavior when resources are fully allocated

```bash
# Deploy 10 pods to exhaust resources
kubectl apply -f manifests/test-pods/test-resource-exhaustion.yaml

# Check how many pods are running vs pending
kubectl get pods -l app=gpu-exhaustion-test -o wide

# View pending reasons
kubectl describe pods -l app=gpu-exhaustion-test | grep -A 5 "Events:"

# Check node resource allocation
kubectl describe nodes | grep -A 10 "Allocated resources:"
```

#### Test 5: Job-based GPU Workload

**What it tests**: Webhook works with Kubernetes Jobs

```bash
# Create a job requesting GPU
kubectl apply -f manifests/test-pods/test-job.yaml

# Check job status
kubectl get jobs

# View job pod status
kubectl get pods -l job-name=test-gpu-job

# Check job logs
kubectl logs job/test-gpu-job
```

### Monitoring Webhook Decisions

#### Real-time Webhook Logs

```bash
# Follow webhook logs (recommended during testing)
kubectl logs -n gpu-webhook -l app=gpu-webhook -f

# Expected log format:
# I1215 14:11:58.443350 1 main.go:60] Reviewing pod: default/test-large-gpu
# I1215 14:11:58.443450 1 main.go:152] Pod default/test-large-gpu requests 3g.30gb MIG
# I1215 14:11:58.476289 1 main.go:180] 3g.30gb, 2g.20gb, and 1g.10gb not available, falling back to basic GPU
# I1215 14:11:58.476742 1 main.go:257] Applied fallback patch to pod default/test-large-gpu
```

#### Webhook Decision Summary

```bash
# View all pods modified by webhook
kubectl get pods --all-namespaces \
  -o jsonpath='{range .items[?(@.metadata.annotations.gpu-webhook\.k8s\.io/fallback)]}{.metadata.namespace}{"/"}{.metadata.name}{"\t"}{.metadata.annotations.gpu-webhook\.k8s\.io/fallback}{"\n"}{end}'
```

#### Node Resource Status

```bash
# Check GPU resource allocation on nodes
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
POOL:.metadata.labels.node-pool,\
MIG-1g:.status.capacity.nvidia\\.com/mig-1g\\.10gb,\
MIG-2g:.status.capacity.nvidia\\.com/mig-2g\\.20gb,\
MIG-3g:.status.capacity.nvidia\\.com/mig-3g\\.30gb,\
GPU:.status.capacity.nvidia\\.com/gpu
```

### Test Results Validation

#### Verify Fallback Annotation

```bash
POD_NAME="test-medium-gpu"

# Check if webhook added fallback annotation
kubectl get pod $POD_NAME \
  -o jsonpath='{.metadata.annotations.gpu-webhook\.k8s\.io/fallback}'

# If empty output: Pod used original resource (no fallback needed)
# If shows "2g.20gb->1g.10gb": Successfully fell back to smaller MIG
# If shows "2g.20gb->gpu": Fell back to basic GPU
```

#### Verify Resource Modification

```bash
POD_NAME="test-medium-gpu"

# Check original request (from kubectl apply)
grep "nvidia.com" manifests/test-pods/test-medium-gpu.yaml

# Check actual assigned resource
kubectl get pod $POD_NAME \
  -o jsonpath='{.spec.containers[0].resources.requests}' | jq .

# Compare: If different, webhook successfully modified the request
```

### Cleanup After Testing

```bash
# Delete all test workloads
kubectl delete -f manifests/test-pods/ --ignore-not-found

# Or use make
make clean-workloads

# To reset everything completely
make clean
```

### Expected Test Outcomes

| Test Case | Original Request | Expected Fallback | Final Resource |
|-----------|------------------|-------------------|----------------|
| test-medium-gpu | nvidia.com/mig-2g.20gb | 2g→1g or 2g→gpu | mig-1g.10gb or gpu |
| test-large-gpu | nvidia.com/mig-3g.30gb | 3g→2g→1g→gpu | First available in chain |
| test-deployment | nvidia.com/mig-2g.20gb | Same for all pods | Consistent across replicas |
| test-resource-exhaustion | nvidia.com/mig-2g.20gb | Some running, some pending | Resource exhaustion validated |

### Advanced Testing

#### Test Concurrent Pod Creation

```bash
# Test webhook handling concurrent requests
for i in {1..10}; do
  kubectl run test-concurrent-$i --image=nvidia/cuda:11.8.0-base-ubuntu22.04 \
    --overrides='{"spec":{"containers":[{"name":"test","image":"nvidia/cuda:11.8.0-base-ubuntu22.04","resources":{"requests":{"nvidia.com/mig-2g.20gb":"1"}}}]}}' &
done

# Wait for all to complete
wait

# Check results
kubectl get pods -l run=test-concurrent -o custom-columns=\
NAME:.metadata.name,\
FALLBACK:.metadata.annotations.gpu-webhook\\.k8s\\.io/fallback,\
STATUS:.status.phase
```

#### Test Webhook Performance

```bash
# Time webhook response
time kubectl run perf-test --image=nginx \
  --overrides='{"spec":{"containers":[{"name":"test","image":"nginx","resources":{"requests":{"nvidia.com/mig-2g.20gb":"1"}}}]}}'

# Check webhook latency in logs
kubectl logs -n gpu-webhook -l app=gpu-webhook | grep "Reviewing pod" | tail -5
```

For more detailed test documentation, see:
- [docs/TEST_REPORT.md](docs/TEST_REPORT.md) - Complete test report
- [docs/RESOURCE_EXHAUSTION_TEST.md](docs/RESOURCE_EXHAUSTION_TEST.md) - Resource exhaustion analysis
- [docs/测试说明.md](docs/测试说明.md) - Chinese test documentation

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

## Documentation

For detailed technical documentation, see:

- **[docs/RESOURCE_CONCEPTS.md](docs/RESOURCE_CONCEPTS.md)** - Deep dive into Available vs Allocated vs Allocatable
  - Complete architecture diagrams showing data flow (Webhook → API Server → etcd)
  - Code examples with actual implementation
  - Performance comparison and why webhook only checks Allocatable
  - Full Pod creation lifecycle explained

- **[docs/FAQ.md](docs/FAQ.md)** - Frequently Asked Questions
  - Webhook compatibility with real NVIDIA GPUs
  - Mixed MIG configuration support
  - How to interact with webhook
  - Resource checking mechanisms
  - Troubleshooting guide

- **[docs/TEST_REPORT.md](docs/TEST_REPORT.md)** - Comprehensive test report

- **[docs/QUICKSTART.md](docs/QUICKSTART.md)** - Quick start guide

- **[docs/测试说明.md](docs/测试说明.md)** - Chinese test documentation

## References

- [fake-gpu-operator GitHub](https://github.com/run-ai/fake-gpu-operator)
- [NVIDIA MIG User Guide](https://docs.nvidia.com/datacenter/tesla/mig-user-guide/)
- [Kubernetes Admission Webhooks](https://kubernetes.io/docs/reference/access-authn-authz/admission-controllers/)
- [Kind Documentation](https://kind.sigs.k8s.io/)
