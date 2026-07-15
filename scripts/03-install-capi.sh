#!/bin/bash
set -euo pipefail

# ============================================================
# Install Cluster API + GCP Provider (CAPG)
# ============================================================

export GCP_PROJECT_ID="${GCP_PROJECT_ID:-your-project-id}"
export GCP_REGION="${GCP_REGION:-asia-southeast2}"
export GCP_CREDENTIALS_FILE="${GCP_CREDENTIALS_FILE:-./credentials/gcp-sa-key.json}"

echo "=== Installing CAPI + GCP Provider ==="

# Validate credentials file exists
if [ ! -f "${GCP_CREDENTIALS_FILE}" ]; then
  echo "Error: Credentials file not found at ${GCP_CREDENTIALS_FILE}"
  echo "Run 01-setup-gcp.sh first"
  exit 1
fi

# Export credentials for clusterctl
export GCP_B64ENCODED_CREDENTIALS=$(base64 -w0 "${GCP_CREDENTIALS_FILE}")

# Initialize CAPI with GCP infrastructure provider
echo ">>> Initializing Cluster API..."
clusterctl init \
  --infrastructure gcp \
  --control-plane kubeadm \
  --bootstrap kubeadm

# Wait for controllers to be ready
echo ">>> Waiting for CAPI controllers..."
kubectl wait --for=condition=Available deployment/capi-controller-manager \
  -n capi-system --timeout=300s

echo ">>> Waiting for CAPG controllers..."
kubectl wait --for=condition=Available deployment/capg-controller-manager \
  -n capg-system --timeout=300s

echo ">>> Waiting for Bootstrap controllers..."
kubectl wait --for=condition=Available deployment/capi-kubeadm-bootstrap-controller-manager \
  -n capi-kubeadm-bootstrap-system --timeout=300s

echo ">>> Waiting for Control Plane controllers..."
kubectl wait --for=condition=Available deployment/capi-kubeadm-control-plane-controller-manager \
  -n capi-kubeadm-control-plane-system --timeout=300s

echo ""
echo "=== CAPI Installation Complete ==="
echo ""
echo "Installed providers:"
clusterctl describe --show-conditions=all
echo ""
echo "Next: Apply workload cluster manifest"
echo "  kubectl apply -f clusters/workload-cluster.yaml"
