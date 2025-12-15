# GPU Allocation Simulation - Project Summary

## Overview

Complete setup for simulating GPU allocation in Kubernetes using:
- **Kind** (local Kubernetes cluster)
- **fake-gpu-operator** (simulates NVIDIA GPUs)
- **Custom admission webhook** (intelligent GPU allocation with fallback)

## GPU Configuration

### Hardware Simulation
- **GPU Model**: NVIDIA H200 with 70GB memory (7g.70gb per card)
- **Total**: 24 H200 GPUs (4 cards × 6 nodes)

### Node Groups

| Group  | Nodes | Cards/Node | MIG Profile per Card | Total MIG Devices |
|--------|-------|------------|---------------------|-------------------|
| Small  | 3     | 4          | 7× 1g.10gb          | 84× 1g.10gb       |
| Medium | 3     | 4          | 3× 2g.20gb + 1× 1g.10gb | 36× 2g.20gb + 12× 1g.10gb |

### Total Cluster Capacity
- **96× 1g.10gb** MIG devices
- **36× 2g.20gb** MIG devices

## Project Structure

```
/home/workspace/github/
├── README.md                          # Complete documentation
├── QUICKSTART.md                      # Fast deployment guide
├── PROJECT_SUMMARY.md                 # This file
├── Makefile                           # Convenient make targets
│
├── kind-gpu-cluster.yaml              # Kind cluster configuration
├── fake-gpu-values.yaml               # Fake GPU operator Helm values
├── setup-cluster.sh                   # Main cluster setup script
├── configure-mig-profiles.sh          # MIG profile configuration script
│
├── webhook/                           # Admission webhook
│   ├── main.go                        # Webhook Go source code
│   ├── go.mod                         # Go module definition
│   ├── Dockerfile                     # Container image build
│   ├── init-go-module.sh              # Initialize Go dependencies
│   ├── generate-certs.sh              # TLS certificate generation
│   ├── build-and-deploy.sh            # Build and deploy webhook
│   └── deploy/                        # Kubernetes manifests
│       ├── 00-namespace.yaml          # gpu-webhook namespace
│       ├── 01-rbac.yaml               # ServiceAccount, ClusterRole, Binding
│       ├── 02-service.yaml            # Webhook service
│       ├── 03-deployment.yaml         # Webhook deployment
│       └── 04-webhook-config.yaml     # MutatingWebhookConfiguration
│
├── test-pods/                         # Test workloads
│   ├── test-medium-gpu.yaml           # Single pod test
│   ├── test-job.yaml                  # Batch job test
│   └── test-deployment.yaml           # Multi-pod deployment test
│
└── fake-gpu-operator/                 # Cloned repository (for reference)
```

## Key Components

### 1. Cluster Configuration (`kind-gpu-cluster.yaml`)
- 1 control-plane node
- 3 small worker nodes (labeled `node-pool: small`)
- 3 medium worker nodes (labeled `node-pool: medium`)

### 2. GPU Operator Values (`fake-gpu-values.yaml`)
Configures fake-gpu-operator with:
- Node pool label key: `run.ai/simulated-gpu-node-pool`
- MIG strategy: `mixed`
- GPU product: `NVIDIA-H200`
- GPU memory: 71680 MiB (70GB)
- 4 GPUs per node

### 3. Setup Scripts

#### `setup-cluster.sh`
Main deployment script that:
1. Creates Kind cluster
2. Installs fake-gpu-operator via Helm
3. Labels nodes for GPU simulation
4. Configures MIG enablement labels
5. Calls `configure-mig-profiles.sh`

#### `configure-mig-profiles.sh`
Applies MIG configurations via node annotations:
- **Small nodes**: 7× 1g.10gb per GPU (4 GPUs)
- **Medium nodes**: 3× 2g.20gb + 1× 1g.10gb per GPU (4 GPUs)

### 4. Admission Webhook

#### Purpose
Automatically adjusts GPU resource requests when preferred sizes are unavailable.

#### Functionality
```go
// User requests: nvidia.com/mig-2g.20gb: 1
// If unavailable → Webhook modifies to: nvidia.com/mig-1g.10gb: 1
// Adds annotation: gpu-webhook.k8s.io/fallback: "2g.20gb->1g.10gb"
```

#### Components
- **main.go**: Webhook server implementation
  - Monitors pod creation requests
  - Checks MIG resource availability across nodes
  - Applies JSON patch to modify GPU requests
  - Adds fallback annotation for transparency

- **Deployment manifests**:
  - RBAC for node list/watch permissions
  - Deployment with TLS-enabled webhook server
  - Service exposing webhook on port 443
  - MutatingWebhookConfiguration for pod interception

- **Certificate generation**:
  - Creates CA and server certificates
  - Configures webhook with proper CA bundle
  - Stores certs in Kubernetes secret

### 5. Test Manifests

#### `test-medium-gpu.yaml`
Tests single pod GPU allocation with medium GPU request.

#### `test-job.yaml`
Tests batch job with GPU requirements.

#### `test-deployment.yaml`
Tests deployment with 3 replicas requesting medium GPUs.
Demonstrates webhook fallback when multiple pods exhaust 2g.20gb resources.

## Deployment Workflow

### Option 1: Using Makefile (Recommended)

```bash
# Complete setup
make all

# Individual steps
make setup           # Setup cluster
make deploy-webhook  # Deploy webhook
make verify          # Verify setup
make test            # Run tests
```

### Option 2: Manual Steps

```bash
# 1. Setup cluster
chmod +x setup-cluster.sh configure-mig-profiles.sh
./setup-cluster.sh

# 2. Deploy webhook
cd webhook
chmod +x *.sh
./init-go-module.sh      # Initialize Go dependencies
./build-and-deploy.sh    # Build and deploy
cd ..

# 3. Test
kubectl apply -f test-pods/test-medium-gpu.yaml
kubectl get pod test-medium-gpu -o yaml
```

## How It Works

### 1. Cluster Creation
```bash
./setup-cluster.sh
```
- Kind creates 7-node cluster (1 control-plane + 6 workers)
- Helm installs fake-gpu-operator
- Nodes get labeled for GPU simulation
- MIG profiles applied via annotations

### 2. Webhook Deployment
```bash
cd webhook && ./build-and-deploy.sh
```
- Docker builds webhook image
- Image loaded into Kind cluster
- TLS certificates generated
- Webhook deployed with proper RBAC
- MutatingWebhookConfiguration applied

### 3. Pod Scheduling

When a user creates a pod:

```yaml
resources:
  requests:
    nvidia.com/mig-2g.20gb: "1"
```

**Webhook intercepts**:
1. Checks if any node has available `nvidia.com/mig-2g.20gb`
2. **If available**: Pod created as-is
3. **If unavailable**:
   - Modifies request to `nvidia.com/mig-1g.10gb: 1`
   - Adds annotation: `gpu-webhook.k8s.io/fallback: "2g.20gb->1g.10gb"`
   - Pod scheduled to node with 1g.10gb MIG

**User benefit**: No need to modify YAML or resubmit — automatic fallback!

## Monitoring

### View Node Resources
```bash
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
POOL:.metadata.labels.node-pool,\
MIG-1g:.status.capacity.nvidia\\.com/mig-1g\\.10gb,\
MIG-2g:.status.capacity.nvidia\\.com/mig-2g\\.20gb
```

### Watch Webhook Decisions
```bash
kubectl logs -n gpu-webhook -l app=gpu-webhook -f
```

### Check Pod GPU Assignments
```bash
kubectl get pods -o custom-columns=\
NAME:.metadata.name,\
FALLBACK:.metadata.annotations.gpu-webhook\\.k8s\\.io/fallback,\
GPU:.spec.containers[0].resources.requests
```

## Key Features

✅ **Automatic GPU fallback** - No user intervention needed
✅ **Transparent annotation** - Users know when fallback occurred
✅ **Works with Pods, Jobs, Deployments** - All workload types supported
✅ **Local development** - Runs entirely in Kind cluster
✅ **Realistic simulation** - Uses actual NVIDIA MIG profiles
✅ **Easy cleanup** - `make clean` or `kind delete cluster`

## Next Steps

1. **Test the setup**: Run `make test` to see webhook in action
2. **Monitor logs**: Use `make logs-webhook` to watch decisions
3. **Experiment**: Create custom workloads in `test-pods/`
4. **Extend**: Add large node pool or modify webhook logic
5. **Integrate**: Adapt for your actual GPU cluster needs

## Customization Ideas

### Add More Node Pools
Edit `kind-gpu-cluster.yaml` and `fake-gpu-values.yaml` to add:
- Large nodes (7g.70gb full GPUs)
- Extra-small nodes (more 1g.10gb instances)

### Enhance Webhook
Modify `webhook/main.go` to:
- Support multi-tier fallback (2g → 1g → fail)
- Add node affinity based on workload labels
- Implement GPU reservations
- Add metrics and alerting

### Production Use
- Replace fake-gpu-operator with real NVIDIA GPU Operator
- Deploy webhook to production cluster
- Add high availability (multiple webhook replicas)
- Implement admission webhook monitoring

## Troubleshooting

See `README.md` section "Troubleshooting" for detailed solutions to common issues.

Quick checks:
```bash
# Cluster healthy?
kubectl get nodes

# GPUs showing?
kubectl get nodes -o yaml | grep nvidia.com/mig

# Webhook running?
kubectl get pods -n gpu-webhook

# Certificates valid?
kubectl get secret gpu-webhook-certs -n gpu-webhook
```

## Resources

- **Full docs**: `README.md`
- **Quick start**: `QUICKSTART.md`
- **Fake GPU Operator**: https://github.com/run-ai/fake-gpu-operator
- **NVIDIA MIG Guide**: https://docs.nvidia.com/datacenter/tesla/mig-user-guide/

---

**Project Status**: Ready to deploy! 🚀

Run `make all` to start the complete setup.
