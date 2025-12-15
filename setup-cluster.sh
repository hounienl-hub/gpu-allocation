#!/bin/bash
set -e

echo "Creating kind cluster..."
kind create cluster --config kind-gpu-cluster.yaml

echo "Waiting for nodes to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=300s

echo "Installing fake-gpu-operator..."
helm upgrade -i gpu-operator oci://ghcr.io/run-ai/fake-gpu-operator/fake-gpu-operator \
  --namespace gpu-operator --create-namespace \
  --values fake-gpu-values.yaml \
  --wait

echo "Labeling nodes for GPU simulation..."
# Label small node
for node in $(kubectl get nodes -l node-pool=small -o jsonpath='{.items[*].metadata.name}'); do
  echo "Configuring small node: $node"
  kubectl label node $node run.ai/simulated-gpu-node-pool=small --overwrite
  kubectl label node $node node-role.kubernetes.io/runai-dynamic-mig=true --overwrite
  kubectl label node $node node-role.kubernetes.io/runai-mig-enabled=true --overwrite
  kubectl label node $node nvidia.com/gpu.product=NVIDIA-H200 --overwrite
done

# Label medium node
for node in $(kubectl get nodes -l node-pool=medium -o jsonpath='{.items[*].metadata.name}'); do
  echo "Configuring medium node: $node"
  kubectl label node $node run.ai/simulated-gpu-node-pool=medium --overwrite
  kubectl label node $node node-role.kubernetes.io/runai-dynamic-mig=true --overwrite
  kubectl label node $node node-role.kubernetes.io/runai-mig-enabled=true --overwrite
  kubectl label node $node nvidia.com/gpu.product=NVIDIA-H200 --overwrite
done

echo "Waiting for fake-gpu-operator pods to be ready..."
kubectl wait --for=condition=Ready pods -n gpu-operator --all --timeout=300s

echo "Configuring MIG profiles on nodes..."
./configure-mig-profiles.sh

echo "Cluster setup complete!"
echo ""
echo "Summary:"
echo "- Small node (1): 4× H200 cards, 7× 1g.10gb MIGs per card = 28× 1g.10gb total"
echo "- Medium node (1): 4× H200 cards, 3× 2g.20gb + 1× 1g.10gb MIGs per card = 12× 2g.20gb + 4× 1g.10gb total"
echo ""
echo "Total Cluster Capacity:"
echo "- 32× 1g.10gb MIG devices"
echo "- 12× 2g.20gb MIG devices"
echo ""
echo "View nodes:"
echo "kubectl get nodes --show-labels"
echo ""
echo "View GPU resources:"
echo "kubectl get nodes -o custom-columns=NAME:.metadata.name,MIG-1g.10gb:.status.capacity.nvidia\\.com/mig-1g\\.10gb,MIG-2g.20gb:.status.capacity.nvidia\\.com/mig-2g\\.20gb"
