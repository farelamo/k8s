#!/bin/bash
set -euo pipefail

# ============================================================
# Pivot: Pindahkan CAPI dari kind ke workload cluster
# Ini membuat workload cluster jadi self-managing
# ============================================================

WORKLOAD_CLUSTER_NAME="${1:-workload-cluster}"
WORKLOAD_KUBECONFIG="./kubeconfigs/${WORKLOAD_CLUSTER_NAME}.kubeconfig"

echo "=== Pivoting Management to ${WORKLOAD_CLUSTER_NAME} ==="

# Get workload cluster kubeconfig
if [ ! -f "${WORKLOAD_KUBECONFIG}" ]; then
  echo ">>> Fetching workload cluster kubeconfig..."
  mkdir -p ./kubeconfigs
  clusterctl get kubeconfig "${WORKLOAD_CLUSTER_NAME}" > "${WORKLOAD_KUBECONFIG}"
fi

# Verify workload cluster is accessible
echo ">>> Verifying workload cluster..."
kubectl --kubeconfig="${WORKLOAD_KUBECONFIG}" cluster-info

# Initialize CAPI on workload cluster
echo ">>> Installing CAPI on workload cluster..."
clusterctl init \
  --infrastructure gcp \
  --control-plane kubeadm \
  --bootstrap kubeadm \
  --kubeconfig="${WORKLOAD_KUBECONFIG}"

# Wait for controllers on workload cluster
echo ">>> Waiting for controllers on workload cluster..."
kubectl --kubeconfig="${WORKLOAD_KUBECONFIG}" wait \
  --for=condition=Available deployment/capi-controller-manager \
  -n capi-system --timeout=300s

# Move CAPI resources from kind to workload cluster
echo ">>> Moving CAPI resources..."
clusterctl move --to-kubeconfig="${WORKLOAD_KUBECONFIG}"

echo ""
echo "=== Pivot Complete ==="
echo ""
echo "Management is now running on: ${WORKLOAD_CLUSTER_NAME}"
echo "You can now delete the kind cluster:"
echo "  kind delete cluster --name capi-management"
echo ""
echo "Use this kubeconfig for management operations:"
echo "  export KUBECONFIG=${WORKLOAD_KUBECONFIG}"
