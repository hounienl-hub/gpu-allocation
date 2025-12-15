.PHONY: help setup deploy-webhook test clean

help: ## Show this help message
	@echo 'Usage: make [target]'
	@echo ''
	@echo 'Available targets:'
	@grep -E '^[a-zA-Z_-]+:.*?## .*$$' $(MAKEFILE_LIST) | sort | awk 'BEGIN {FS = ":.*?## "}; {printf "  \033[36m%-20s\033[0m %s\n", $$1, $$2}'

setup: ## Setup the Kind cluster with fake-gpu-operator
	@echo "Setting up Kind cluster with GPU simulation..."
	chmod +x scripts/setup-cluster.sh scripts/configure-mig-profiles.sh
	./scripts/setup-cluster.sh

deploy-webhook: ## Build and deploy the GPU allocation webhook
	@echo "Building and deploying webhook..."
	cd webhook && chmod +x scripts/*.sh && ./scripts/init-go-module.sh && ./scripts/build-and-deploy.sh

test: ## Deploy test workloads
	@echo "Deploying test workloads..."
	kubectl apply -f manifests/test-pods/test-medium-gpu.yaml
	@echo "Waiting for pod to be scheduled..."
	@sleep 5
	@echo "\nPod details:"
	kubectl get pod test-medium-gpu -o custom-columns=\
NAME:.metadata.name,\
STATUS:.status.phase,\
FALLBACK:.metadata.annotations.gpu-webhook\\.k8s\\.io/fallback,\
GPU-REQUEST:.spec.containers[0].resources.requests
	@echo "\nWebhook logs:"
	kubectl logs -n gpu-webhook -l app=gpu-webhook --tail=10

verify: ## Verify the setup
	@echo "Checking nodes..."
	kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
POOL:.metadata.labels.node-pool,\
STATUS:.status.conditions[3].type,\
MIG-1g:.status.capacity.nvidia\\.com/mig-1g\\.10gb,\
MIG-2g:.status.capacity.nvidia\\.com/mig-2g\\.20gb
	@echo "\nChecking fake-gpu-operator..."
	kubectl get pods -n gpu-operator
	@echo "\nChecking webhook..."
	kubectl get pods -n gpu-webhook

logs-webhook: ## View webhook logs
	kubectl logs -n gpu-webhook -l app=gpu-webhook -f

logs-operator: ## View fake-gpu-operator logs
	kubectl logs -n gpu-operator -l app.kubernetes.io/name=fake-gpu-operator -f

clean-workloads: ## Delete test workloads
	kubectl delete -f manifests/test-pods/ --ignore-not-found=true

clean: ## Delete the entire cluster
	kind delete cluster --name gpu-sim-cluster

all: setup deploy-webhook verify ## Complete setup and deployment
