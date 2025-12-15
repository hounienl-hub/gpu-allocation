#!/bin/bash
set -e

# Configure MIG profiles for small nodes
# Small nodes: 7x 1g.10gb MIGs per GPU, 4 GPUs per node
for node in $(kubectl get nodes -l node-pool=small -o jsonpath='{.items[*].metadata.name}'); do
  echo "Configuring MIG profile for small node: $node"

  # MIG configuration with 7x 1g.10gb per GPU for 4 GPUs
  kubectl annotate node $node run.ai/mig.config='version: v1
mig-configs:
  selected:
  - devices: [0]
    mig-enabled: true
    mig-devices:
      0: 1g.10gb
      1: 1g.10gb
      2: 1g.10gb
      3: 1g.10gb
      4: 1g.10gb
      5: 1g.10gb
      6: 1g.10gb
  - devices: [1]
    mig-enabled: true
    mig-devices:
      0: 1g.10gb
      1: 1g.10gb
      2: 1g.10gb
      3: 1g.10gb
      4: 1g.10gb
      5: 1g.10gb
      6: 1g.10gb
  - devices: [2]
    mig-enabled: true
    mig-devices:
      0: 1g.10gb
      1: 1g.10gb
      2: 1g.10gb
      3: 1g.10gb
      4: 1g.10gb
      5: 1g.10gb
      6: 1g.10gb
  - devices: [3]
    mig-enabled: true
    mig-devices:
      0: 1g.10gb
      1: 1g.10gb
      2: 1g.10gb
      3: 1g.10gb
      4: 1g.10gb
      5: 1g.10gb
      6: 1g.10gb' --overwrite
done

# Configure MIG profiles for medium nodes
# Medium nodes: 3x 2g.20gb + 1x 1g.10gb MIGs per GPU, 4 GPUs per node
for node in $(kubectl get nodes -l node-pool=medium -o jsonpath='{.items[*].metadata.name}'); do
  echo "Configuring MIG profile for medium node: $node"

  # MIG configuration with 3x 2g.20gb + 1x 1g.10gb per GPU for 4 GPUs
  kubectl annotate node $node run.ai/mig.config='version: v1
mig-configs:
  selected:
  - devices: [0]
    mig-enabled: true
    mig-devices:
      0: 2g.20gb
      2: 2g.20gb
      4: 2g.20gb
      6: 1g.10gb
  - devices: [1]
    mig-enabled: true
    mig-devices:
      0: 2g.20gb
      2: 2g.20gb
      4: 2g.20gb
      6: 1g.10gb
  - devices: [2]
    mig-enabled: true
    mig-devices:
      0: 2g.20gb
      2: 2g.20gb
      4: 2g.20gb
      6: 1g.10gb
  - devices: [3]
    mig-enabled: true
    mig-devices:
      0: 2g.20gb
      2: 2g.20gb
      4: 2g.20gb
      6: 1g.10gb' --overwrite
done

echo "MIG profiles configured successfully"
