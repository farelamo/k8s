#!/bin/bash
set -euo pipefail

# ============================================================
# Bootstrap Management Cluster menggunakan kind
# ============================================================

CLUSTER_NAME="capi-management"

echo "=== Bootstrapping Management Cluster ==="

# Check prerequisites
command -v kind >/dev/null 2>&1 || { echo "Error: kind not installed"; exit 1; }
command -v kubectl >/dev/null 2>&1 || { echo "Error: kubectl not installed"; exit 1; }
command -v clusterctl >/dev/null 2>&1 || { echo "Error: clusterctl not installed"; exit 1; }

# Check if cluster already exists
if kind get clusters 2>/dev/null | grep -q "${CLUSTER_NAME}"; then
  echo "Management cluster '${CLUSTER_NAME}' already exists"
  kubectl cluster-info --context "kind-${CLUSTER_NAME}"
  exit 0
fi

# Create kind cluster with extra port mappings
echo ">>> Creating kind cluster..."
cat <<EOF | kind create cluster --name "${CLUSTER_NAME}" --config=-
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 6443
    hostPort: 6443
    protocol: TCP
networking:
  podSubnet: "10.244.0.0/16"
  serviceSubnet: "10.96.0.0/12"
EOF

# Wait for cluster to be ready
echo ">>> Waiting for cluster to be ready..."
kubectl wait --for=condition=Ready nodes --all --timeout=120s

echo ""
echo "=== Management Cluster Ready ==="
echo "Context: kind-${CLUSTER_NAME}"
kubectl cluster-info --context "kind-${CLUSTER_NAME}"
