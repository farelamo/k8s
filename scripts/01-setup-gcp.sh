#!/bin/bash
set -euo pipefail

# ============================================================
# Setup GCP untuk CAPI
# ============================================================

# Konfigurasi - sesuaikan dengan environment kamu
export GCP_PROJECT_ID="${GCP_PROJECT_ID:-your-project-id}"
export GCP_REGION="${GCP_REGION:-asia-southeast2}"
export GCP_ZONE="${GCP_ZONE:-asia-southeast2-a}"
export GCP_SERVICE_ACCOUNT_NAME="fariz-capi-manager"
export GCP_SERVICE_ACCOUNT_EMAIL="${GCP_SERVICE_ACCOUNT_NAME}@${GCP_PROJECT_ID}.iam.gserviceaccount.com"
export GCP_CREDENTIALS_FILE="./credentials/gcp-sa-key.json"

echo "=== Setting up GCP for CAPI ==="
echo "Project: ${GCP_PROJECT_ID}"
echo "Region: ${GCP_REGION}"

# Set project
gcloud config set project "${GCP_PROJECT_ID}"

# Enable required APIs
echo ">>> Enabling required GCP APIs..."
gcloud services enable compute.googleapis.com
gcloud services enable iam.googleapis.com
gcloud services enable cloudresourcemanager.googleapis.com

# Create Service Account
echo ">>> Creating Service Account..."
gcloud iam service-accounts create "${GCP_SERVICE_ACCOUNT_NAME}" \
  --display-name="CAPI Manager" \
  --description="Service account for Cluster API GCP provider" \
  2>/dev/null || echo "Service account already exists"

# Assign roles
echo ">>> Assigning IAM roles..."
ROLES=(
  "roles/compute.admin"
  "roles/iam.serviceAccountUser"
  "roles/iam.serviceAccountAdmin"
  "roles/storage.admin"
  "roles/compute.loadBalancerAdmin"
)

for role in "${ROLES[@]}"; do
  gcloud projects add-iam-policy-binding "${GCP_PROJECT_ID}" \
    --member="serviceAccount:${GCP_SERVICE_ACCOUNT_EMAIL}" \
    --role="${role}" \
    --quiet
done

# Create key file
echo ">>> Creating service account key..."
mkdir -p ./credentials
gcloud iam service-accounts keys create "${GCP_CREDENTIALS_FILE}" \
  --iam-account="${GCP_SERVICE_ACCOUNT_EMAIL}"

echo ""
echo "=== GCP Setup Complete ==="
echo "Credentials saved to: ${GCP_CREDENTIALS_FILE}"
echo ""
echo "Export these for CAPI:"
echo "  export GCP_B64ENCODED_CREDENTIALS=\$(base64 -w0 ${GCP_CREDENTIALS_FILE})"
echo "  export GCP_PROJECT=${GCP_PROJECT_ID}"
echo "  export GCP_REGION=${GCP_REGION}"
