#!/bin/bash
set -e

echo "Building webhook Docker image..."
docker build -t gpu-webhook:latest .

echo "Loading image into kind cluster..."
kind load docker-image gpu-webhook:latest --name gpu-sim-cluster

echo "Generating certificates..."
chmod +x generate-certs.sh
./generate-certs.sh

echo "Deploying webhook to Kubernetes..."
kubectl apply -f deploy/00-namespace.yaml
kubectl apply -f deploy/01-rbac.yaml
kubectl apply -f deploy/02-service.yaml
kubectl apply -f deploy/03-deployment.yaml

echo "Waiting for webhook deployment to be ready..."
kubectl wait --for=condition=Available deployment/gpu-webhook -n gpu-webhook --timeout=120s

echo "Applying webhook configuration..."
kubectl apply -f deploy/04-webhook-config-patched.yaml

echo "Webhook deployed successfully!"
echo ""
echo "Verify webhook is running:"
echo "kubectl get pods -n gpu-webhook"
echo ""
echo "View webhook logs:"
echo "kubectl logs -n gpu-webhook -l app=gpu-webhook -f"
