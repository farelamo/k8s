# Deployment Guide — Step by Step

Semua di GCP. Tidak ada lokal. Management cluster pakai kubeadm (K8s murni).
Semua VM: e2-medium, 30GB disk, Ubuntu 24.04 LTS, region asia-southeast2 (Jakarta).

## Arsitektur

```
┌─── GCP (asia-southeast2 / Jakarta) ─────────────────────────┐
│                                                                │
│  VPC: pcs-production                                           │
│  Subnet: pcs-kubernetes (10.88.18.0/24)                        │
│                                                                │
│  ┌──────────────────────────────────────┐                     │
│  │ fariz-k8s-management-cluster (1 VM)   │                     │
│  │ e2-medium, 30GB, kubeadm single-node  │                     │
│  │                                        │                     │
│  │ - CAPI Core Controller                 │                     │
│  │ - CAPG (GCP Provider)                  │                     │
│  │ - Bootstrap Provider (kubeadm)         │                     │
│  │ - Control Plane Provider (kubeadm)     │                     │
│  │ - Cluster Autoscaler                   │                     │
│  │                                        │                     │
│  │ Manages: ─────────────────────────────┐│                     │
│  └────────────────────────────────────────┘│                     │
│                                            ▼                    │
│  ┌──────────────────────────────────────────────────────────┐  │
│  │ fariz-workload-cluster                                    │  │
│  │ - 3x Control Plane (HA), e2-medium                        │  │
│  │ - 1-10x Workers (autoscaled), e2-medium                   │  │
│  │ - Cilium, Traefik, cert-manager, Jenkins, Apps            │  │
│  └──────────────────────────────────────────────────────────┘  │
│                                                                │
└────────────────────────────────────────────────────────────────┘
```

---

## Prerequisites

Di mesin kamu (sementara, untuk SSH ke management VM):
- `gcloud` CLI
- SSH access ke GCP

---

## Phase 1: Setup GCP Project

Jalankan dari laptop/Cloud Shell:

```bash
# Login & set project
gcloud auth login
gcloud config set project YOUR_PROJECT_ID
gcloud config set compute/region asia-southeast2
gcloud config set compute/zone asia-southeast2-a

# Enable APIs
gcloud services enable compute.googleapis.com
gcloud services enable iam.googleapis.com
gcloud services enable cloudresourcemanager.googleapis.com

# Buat Service Account untuk CAPI
gcloud iam service-accounts create fariz-capi-manager \
  --display-name="CAPI Manager"

# Assign roles
for role in roles/compute.admin roles/iam.serviceAccountUser roles/iam.serviceAccountAdmin roles/storage.admin roles/compute.loadBalancerAdmin; do
  gcloud projects add-iam-policy-binding YOUR_PROJECT_ID \
    --member="serviceAccount:fariz-capi-manager@YOUR_PROJECT_ID.iam.gserviceaccount.com" \
    --role="$role" --quiet
done

# Download key
gcloud iam service-accounts keys create ~/capi-sa-key.json \
  --iam-account=fariz-capi-manager@YOUR_PROJECT_ID.iam.gserviceaccount.com
```

---

## Phase 2: Buat Management VM & Firewall

Jalankan dari laptop/Cloud Shell:

```bash
# Firewall rules — HANYA yang tidak di-handle CAPI
gcloud compute firewall-rules create fariz-k8s-allow-ssh \
  --network=pcs-production \
  --allow=tcp:22 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=management

gcloud compute firewall-rules create fariz-k8s-allow-lb-healthcheck \
  --network=pcs-production \
  --allow=tcp:30000-32767 \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --target-tags=worker

gcloud compute firewall-rules create fariz-k8s-allow-http \
  --network=pcs-production \
  --allow=tcp:80,tcp:443 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=worker

# Buat VM
gcloud compute instances create fariz-k8s-management-cluster \
  --zone=asia-southeast2-a \
  --machine-type=e2-medium \
  --image-project=ubuntu-os-cloud \
  --image-family=ubuntu-2404-lts-amd64 \
  --boot-disk-size=30GB \
  --boot-disk-type=pd-ssd \
  --network-interface=network=pcs-production,subnet=pcs-kubernetes,no-address \
  --tags=management,apiserver \
  --scopes=cloud-platform
```

**SSH ke VM:**
```bash
gcloud compute ssh fariz-k8s-management-cluster --zone=asia-southeast2-a
```

---

## Phase 3: Setup Management VM

Semua command dari sini dijalankan **di dalam VM management**.

```bash
# Update & install dependencies
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg jq

# Kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

# Sysctl
cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
sudo sysctl --system

# Install containerd
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# Install kubeadm, kubelet, kubectl (v1.31)
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet=1.31.* kubeadm=1.31.* kubectl=1.31.*
sudo apt-mark hold kubelet kubeadm kubectl

# Install clusterctl
curl -L https://github.com/kubernetes-sigs/cluster-api/releases/latest/download/clusterctl-linux-amd64 -o clusterctl
chmod +x clusterctl
sudo mv clusterctl /usr/local/bin/

# Install Helm
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

---

## Phase 4: Bootstrap Management Cluster

```bash
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --kubernetes-version=v1.31.0

# Setup kubeconfig
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Untaint (single node, harus bisa schedule pods)
kubectl taint nodes --all node-role.kubernetes.io/control-plane-

# Verify
kubectl get nodes
# STATUS: NotReady (belum ada CNI, normal)
```

---

## Phase 5: Install Cilium di Management Cluster

```bash
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=false \
  --set operator.replicas=1

# Tunggu ready
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes
# STATUS: Ready
```

---

## Phase 6: Install CAPI + GCP Provider

```bash
# Upload SA key (dari laptop):
# gcloud compute scp ~/capi-sa-key.json fariz-k8s-management-cluster:~/capi-sa-key.json --zone=asia-southeast2-a

# Export credentials
export GCP_B64ENCODED_CREDENTIALS=$(base64 -w0 ~/capi-sa-key.json)

# Install CAPI
clusterctl init \
  --infrastructure gcp \
  --control-plane kubeadm \
  --bootstrap kubeadm

# Tunggu controllers ready
kubectl wait --for=condition=Available deployment --all -n capi-system --timeout=300s
kubectl wait --for=condition=Available deployment --all -n capg-system --timeout=300s
kubectl wait --for=condition=Available deployment --all -n capi-kubeadm-bootstrap-system --timeout=300s
kubectl wait --for=condition=Available deployment --all -n capi-kubeadm-control-plane-system --timeout=300s

# Verify
kubectl get pods -A | grep -E "capi|capg"
# Semua harus Running
```

---

## Phase 7: Build Kubernetes Node Image

Buat VM temporary, install K8s tools, buat image dari disk-nya:

```bash
# Dari management VM — buat VM temporary untuk image
gcloud compute instances create fariz-k8s-image-builder \
  --zone=asia-southeast2-a \
  --machine-type=e2-medium \
  --image-project=ubuntu-os-cloud \
  --image-family=ubuntu-2404-lts-amd64 \
  --boot-disk-size=30GB \
  --network-interface=network=pcs-production,subnet=pcs-kubernetes

# SSH ke VM image builder
gcloud compute ssh fariz-k8s-image-builder --zone=asia-southeast2-a
```

**Di dalam VM image builder:**
```bash
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl

# Kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
EOF
sudo modprobe overlay
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/k8s.conf
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
net.ipv6.conf.all.forwarding        = 1
EOF
sudo sysctl --system

# Install containerd
sudo apt-get install -y containerd
sudo mkdir -p /etc/containerd
containerd config default | sudo tee /etc/containerd/config.toml
sudo sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
sudo systemctl restart containerd
sudo systemctl enable containerd

# Install kubeadm, kubelet, kubectl
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list
sudo apt-get update
sudo apt-get install -y kubelet kubeadm kubectl
sudo apt-mark hold kubelet kubeadm kubectl

# Pre-pull images
sudo kubeadm config images pull --kubernetes-version=v1.31.0

# BPF filesystem untuk Cilium
echo "bpffs /sys/fs/bpf bpf defaults 0 0" | sudo tee -a /etc/fstab

# Cleanup
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*
sudo truncate -s 0 /var/log/*.log
sudo rm -rf /tmp/*

# Exit
exit
```

**Kembali di management VM — buat image:**
```bash
gcloud compute instances stop fariz-k8s-image-builder --zone=asia-southeast2-a

gcloud compute images create fariz-k8s-node-v1310 \
  --source-disk=fariz-k8s-image-builder \
  --source-disk-zone=asia-southeast2-a \
  --family=fariz-k8s-ubuntu-2404

# Cleanup
gcloud compute instances delete fariz-k8s-image-builder --zone=asia-southeast2-a --quiet

# Verify
gcloud compute images list --filter="name=fariz-k8s-node-v1310"
```

---

## Phase 8: Reserve Static IP untuk Traefik

```bash
gcloud compute addresses create fariz-traefik-lb-ip --region=asia-southeast2
gcloud compute addresses describe fariz-traefik-lb-ip --region=asia-southeast2 --format='get(address)'
# Catat IP ini → untuk DNS nanti
```

---

## Phase 9: Deploy Workload Cluster

```bash
# Set variable
export GCP_PROJECT_ID="YOUR_PROJECT_ID"

# Apply manifest (envsubst ganti ${GCP_PROJECT_ID} di file)
envsubst < clusters/fariz-workload-cluster.yaml | kubectl apply -f -
```

**Monitor (5-15 menit):**
```bash
kubectl get cluster -w
kubectl get machines -w

# Detail jika error
kubectl describe cluster fariz-workload-cluster
kubectl describe gcpmachine -l cluster.x-k8s.io/cluster-name=fariz-workload-cluster
```

**Get workload kubeconfig:**
```bash
clusterctl get kubeconfig fariz-workload-cluster > $HOME/workload.kubeconfig

kubectl --kubeconfig=$HOME/workload.kubeconfig get nodes
# STATUS NotReady (belum ada CNI, normal)
```

---

## Phase 10: Install Addons di Workload Cluster

```bash
export KUBECONFIG=$HOME/workload.kubeconfig
```

### 10a. Cilium (CNI + kube-proxy replacement)

```bash
API_SERVER=$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https://||' | cut -d: -f1)

helm install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="${API_SERVER}" \
  --set k8sServicePort=6443 \
  --set ipam.mode=kubernetes \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set bpf.masquerade=true \
  --set bandwidthManager.enabled=true \
  --set loadBalancer.algorithm=maglev \
  --set operator.replicas=2

kubectl wait --for=condition=Ready nodes --all --timeout=300s
```

### 10b. Cloud Provider GCP

```bash
kubectl apply -f addons/cloud-provider-gcp.yaml
```

### 10c. Metrics Server

```bash
kubectl apply -f addons/metrics-server.yaml
```

### 10d. Traefik

```bash
TRAEFIK_IP=$(gcloud compute addresses describe fariz-traefik-lb-ip --region=asia-southeast2 --format='get(address)')

helm repo add traefik https://traefik.github.io/charts
helm install traefik traefik/traefik \
  --namespace traefik --create-namespace \
  -f addons/traefik-helm-values.yaml \
  --set service.spec.loadBalancerIP="${TRAEFIK_IP}"

kubectl get svc traefik -n traefik
# EXTERNAL-IP harus = TRAEFIK_IP
```

### 10e. cert-manager

```bash
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  -f addons/cert-manager-helm-values.yaml

kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=120s

export ACME_EMAIL="kamu@yourdomain.com"
envsubst < addons/cert-manager-issuers.yaml | kubectl apply -f -
```

---

## Phase 11: Setup DNS

Buat A record di DNS provider:

```
A    *.yourdomain.com    → <TRAEFIK_IP>
```

Verify:
```bash
dig jenkins.yourdomain.com +short
```

---

## Phase 12: Deploy Jenkins

```bash
kubectl apply -f jenkins/manifests/

kubectl get pods -n jenkins -w
# Tunggu Running (3-5 menit)

# Akses: https://jenkins.yourdomain.com
# Username: admin / Password: admin123 (GANTI!)
```

---

## Phase 13: Setup Registry Credentials

```bash
cat ~/capi-sa-key.json | \
  jq -r '{auths: {"asia-southeast2-docker.pkg.dev": {username: "_json_key", password: (. | tostring)}}}' \
  > ~/docker-config.json

gcloud artifacts repositories create docker-repo \
  --repository-format=docker \
  --location=asia-southeast2

kubectl create secret generic gcr-credentials \
  --namespace jenkins \
  --from-file=config.json=~/docker-config.json

kubectl create namespace production
kubectl create namespace staging

for ns in production staging; do
  kubectl create secret docker-registry gcr-secret \
    --docker-server=asia-southeast2-docker.pkg.dev \
    --docker-username=_json_key \
    --docker-password="$(cat ~/capi-sa-key.json)" \
    --namespace=$ns
done
```

---

## Phase 14: Deploy Cluster Autoscaler

Autoscaler jalan di **management cluster**:

```bash
export KUBECONFIG=~/.kube/config

kubectl create secret generic management-cluster-kubeconfig \
  --from-file=value=$HOME/workload.kubeconfig

kubectl apply -k autoscaling/

# Verify
kubectl get pods -l app=cluster-autoscaler
kubectl logs -l app=cluster-autoscaler --tail=20
```

---

## Phase 15: Verify

```bash
export KUBECONFIG=$HOME/workload.kubeconfig

kubectl get nodes -o wide
kubectl get pods -A | grep -v Running
kubectl get svc traefik -n traefik
kubectl get certificates -A
curl -sI https://jenkins.yourdomain.com | head -5
```

---

## Done!

```
✓ Management Cluster  — 1 VM (e2-medium, 30GB), kubeadm, always-on
✓ Workload Cluster    — 3 CP + 2 Workers (e2-medium, 30GB), HA
✓ Cilium              — CNI + kube-proxy replacement
✓ Traefik             — Ingress, static IP
✓ cert-manager        — Auto TLS Let's Encrypt
✓ Jenkins             — CI/CD, dynamic agents
✓ Cluster Autoscaler  — Scale workers 1-10
✓ Hubble              — Network observability
```

---

## Troubleshooting

### Machine stuck Provisioning
```bash
export KUBECONFIG=~/.kube/config
kubectl describe gcpmachine <name>
# Cek: quota exceeded? Image not found? Network error?
```

### Nodes NotReady
```bash
export KUBECONFIG=$HOME/workload.kubeconfig
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium
```

### Certificate not issuing
```bash
kubectl get challenges -A
# Pastikan DNS propagate & firewall allow 80/443
```

### Management VM down
```bash
# Workload cluster tetap jalan, tapi autoscaling mati
gcloud compute instances start fariz-k8s-management-cluster --zone=asia-southeast2-a
```
