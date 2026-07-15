# Deployment Guide — Step by Step

Semua di GCP. Tidak ada lokal. Management cluster pakai kubeadm (K8s murni).

## Arsitektur

```
┌─── GCP ──────────────────────────────────────────────────────┐
│                                                                │
│  ┌──────────────────────────────────────┐                     │
│  │ Management Cluster (1 VM)             │                     │
│  │ e2-medium, kubeadm single-node        │                     │
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
│  │ Workload Cluster                                          │  │
│  │ - 3x Control Plane (HA)                                   │  │
│  │ - 2-10x Workers (autoscaled)                              │  │
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

## Phase 2: Buat Management VM

```bash
# Firewall rules — HANYA yang tidak di-handle CAPI
# CAPI otomatis buat firewall untuk: API server, etcd, kubelet, internal pods

# SSH ke management VM (untuk kamu akses)
gcloud compute firewall-rules create fariz-k8s-allow-ssh \
  --network=pcs-production \
  --allow=tcp:22 \
  --source-ranges=0.0.0.0/0 \
  --target-tags=management

# GCP LB Health Checks (wajib supaya Load Balancer bisa probe nodes)
gcloud compute firewall-rules create fariz-k8s-allow-lb-healthcheck \
  --network=pcs-production \
  --allow=tcp:30000-32767 \
  --source-ranges=130.211.0.0/22,35.191.0.0/16 \
  --target-tags=worker

# HTTP/HTTPS dari internet ke worker nodes (untuk Traefik)
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
  --boot-disk-size=50GB \
  --boot-disk-type=pd-ssd \
  --network-interface=network=pcs-production,subnet=pcs-kubernetes,no-address \
  --metadata=startup-script='#!/bin/bash
echo "VM ready"' \
  --tags=management,apiserver \
  --scopes=cloud-platform
```

**SSH ke VM:**
```bash
gcloud compute ssh fariz-k8s-management-cluster --zone=asia-southeast2-a
```

---

## Phase 3: Setup Management VM (di dalam VM)

Setelah SSH ke management VM, jalankan semua ini:

```bash
# ============================================================
# Install Container Runtime (containerd)
# ============================================================
sudo apt-get update
sudo apt-get install -y apt-transport-https ca-certificates curl gnupg

# Load kernel modules
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

# ============================================================
# Install kubeadm, kubelet, kubectlsudo apt-mark unhold kubelet kubeadm kubectl
sudo apt-get update


# ============================================================
curl -fsSL https://pkgs.k8s.io/core:/stable:/v1.31/deb/Release.key | sudo gpg --dearmor -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
echo 'deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/v1.31/deb/ /' | sudo tee /etc/apt/sources.list.d/kubernetes.list

sudo apt-get update
sudo apt-get install -y kubelet=1.31.* kubeadm=1.31.* kubectl=1.31.*
sudo apt-mark hold kubelet kubeadm kubectl

# ============================================================
# Install clusterctl
# ============================================================
curl -L https://github.com/kubernetes-sigs/cluster-api/releases/latest/download/clusterctl-linux-amd64 -o clusterctl
chmod +x clusterctl
sudo mv clusterctl /usr/local/bin/

# ============================================================
# Install Helm
# ============================================================
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
```

---

## Phase 4: Bootstrap Management Cluster (kubeadm, di VM)

```bash
# Init single-node control plane
sudo kubeadm init \
  --pod-network-cidr=10.244.0.0/16 \
  --service-cidr=10.96.0.0/12 \
  --kubernetes-version=v1.31.0

# Setup kubeconfig
mkdir -p $HOME/.kube
sudo cp /etc/kubernetes/admin.conf $HOME/.kube/config
sudo chown $(id -u):$(id -g) $HOME/.kube/config

# Untaint control-plane (supaya pods bisa schedule di node ini)
# Karena single node, harus di-untaint
kubectl taint nodes --all node-role.kubernetes.io/control-plane-

# Verify
kubectl get nodes
# STATUS: NotReady (belum ada CNI, normal)
```

---

## Phase 5: Install Cilium di Management Cluster

Management cluster juga butuh CNI supaya pods bisa running.

```bash
# Install Cilium (versi simple, tanpa kube-proxy replacement untuk mgmt)
helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=false \
  --set operator.replicas=1

# Tunggu sampai ready
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes
# STATUS: Ready
```

---

## Phase 6: Install CAPI + GCP Provider

```bash
# Upload service account key ke VM (dari mesin lokal)
# Di mesin lokal:
# gcloud compute scp ~/capi-sa-key.json fariz-k8s-management-cluster:~/capi-sa-key.json --zone=asia-southeast2-a

# Di VM: Export credentials
export GCP_B64ENCODED_CREDENTIALS=$(base64 -w0 ~/capi-sa-key.json)

# Initialize CAPI
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

Buat image manual (tanpa image-builder):

```bash
# Buat VM temporary
gcloud compute instances create fariz-k8s-image-builder \
  --zone=asia-southeast2-a \
  --machine-type=e2-medium \
  --image-project=ubuntu-os-cloud \
  --image-family=ubuntu-2404-lts-amd64 \
  --boot-disk-size=30GB \
  --network-interface=network=pcs-production,subnet=pcs-kubernetes

# SSH ke VM itu
gcloud compute ssh fariz-k8s-image-builder --zone=asia-southeast2-a

# === Di dalam VM image builder ===

# Update
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

# Pre-pull images (biar boot cepat nanti)
sudo kubeadm config images pull --kubernetes-version=v1.31.0

# Mount BPF filesystem (untuk Cilium)
echo "bpffs /sys/fs/bpf bpf defaults 0 0" | sudo tee -a /etc/fstab

# Cleanup
sudo apt-get clean
sudo rm -rf /var/lib/apt/lists/*
sudo truncate -s 0 /var/log/*.log
sudo rm -rf /tmp/*

# Exit VM
exit

# === Kembali di management VM ===

# Stop VM dan buat image
gcloud compute instances stop fariz-k8s-image-builder --zone=asia-southeast2-a
gcloud compute images create fariz-k8s-node-v1310 \
  --source-disk=fariz-k8s-image-builder \
  --source-disk-zone=asia-southeast2-a \
  --family=fariz-k8s-ubuntu-2404

# Cleanup VM temporary
gcloud compute instances delete fariz-k8s-image-builder --zone=asia-southeast2-a --quiet

# Verify image ada
gcloud compute images list --filter="name=fariz-k8s-node-v1310"
```

**Setelah selesai**, update image di manifest workload cluster:
- Image name: `projects/YOUR_PROJECT_ID/global/images/fariz-k8s-node-v1310`

---

## Phase 8: Reserve Static IP untuk Traefik

VPC dan subnet sudah ada (`pcs-production` / `pcs-kubernetes` / `10.88.18.0/24`).
Tinggal reserve static IP untuk Traefik Load Balancer:

```bash
# Reserve static IP
gcloud compute addresses create fariz-traefik-lb-ip --region=asia-southeast2
gcloud compute addresses describe fariz-traefik-lb-ip --region=asia-southeast2 --format='get(address)'
# Catat IP ini! Akan dipakai untuk DNS nanti.
```

---

## Phase 9: Deploy Workload Cluster

Buat file workload cluster manifest (sudah ada di repo, tapi sesuaikan value):

```bash
# Di VM management, clone/upload repo k8s/ kamu
# Atau buat langsung:

export GCP_PROJECT_ID="YOUR_PROJECT_ID"
export NODE_IMAGE="projects/YOUR_PROJECT_ID/global/images/YOUR_IMAGE_NAME"

# Edit clusters/fariz-workload-cluster.yaml:
# - Ganti ${GCP_PROJECT_ID} dengan project id kamu
# - Ganti image field dengan $NODE_IMAGE
# Atau pakai envsubst jika sudah setup variable di manifest

# Apply
envsubst < clusters/fariz-workload-cluster.yaml | kubectl apply -f -
```

**Monitor:**
```bash
# Watch cluster provisioning
kubectl get cluster -w
kubectl get machines -w

# Detail jika error
kubectl describe cluster fariz-workload-cluster
kubectl describe gcpmachine -l cluster.x-k8s.io/cluster-name=fariz-workload-cluster

# Tunggu sampai:
# Cluster PHASE = Provisioned
# All machines PHASE = Running
# (5-15 menit)
```

**Get workload kubeconfig:**
```bash
clusterctl get kubeconfig fariz-workload-cluster > ~/workload.kubeconfig

# Test akses
kubectl --kubeconfig=~/workload.kubeconfig get nodes
# Nodes ada tapi STATUS NotReady (belum ada CNI)
```

---

## Phase 10: Install Addons di Workload Cluster

Mulai sekarang, semua command pakai workload kubeconfig:

```bash
export KUBECONFIG=~/workload.kubeconfig
```

### 10a. Cilium (CNI + kube-proxy replacement)

```bash
# Dapatkan API server endpoint
API_SERVER=$(kubectl config view -o jsonpath='{.clusters[0].cluster.server}' | sed 's|https://||' | cut -d: -f1)

helm repo add cilium https://helm.cilium.io/
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

# Tunggu nodes Ready
kubectl wait --for=condition=Ready nodes --all --timeout=300s
kubectl get nodes
# Semua harus Ready
```

### 10b. Cloud Provider GCP

```bash
kubectl apply -f addons/cloud-provider-gcp.yaml

# Verify
kubectl get pods -n kube-system -l component=cloud-controller-manager
```

### 10c. Metrics Server

```bash
kubectl apply -f addons/metrics-server.yaml

# Verify (tunggu 1 menit)
kubectl top nodes
```

### 10d. Traefik

```bash
# Dapatkan static IP yang sudah di-reserve
TRAEFIK_IP=$(gcloud compute addresses describe fariz-traefik-lb-ip --region=asia-southeast2 --format='get(address)')
echo "Traefik IP: ${TRAEFIK_IP}"

helm repo add traefik https://traefik.github.io/charts
helm install traefik traefik/traefik \
  --namespace traefik --create-namespace \
  -f addons/traefik-helm-values.yaml \
  --set service.spec.loadBalancerIP="${TRAEFIK_IP}"

# Verify
kubectl get svc traefik -n traefik
# EXTERNAL-IP harus = IP yang kamu reserve
```

### 10e. cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  -f addons/cert-manager-helm-values.yaml

# Tunggu ready
kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=120s

# Buat ClusterIssuers
export ACME_EMAIL="kamu@yourdomain.com"
envsubst < addons/cert-manager-issuers.yaml | kubectl apply -f -

# Verify
kubectl get clusterissuer
# Ready = True
```

---

## Phase 11: Setup DNS

Di DNS provider kamu, buat A record pointing ke Traefik IP:

```
A    jenkins.yourdomain.com    → <TRAEFIK_IP>
A    app.yourdomain.com        → <TRAEFIK_IP>
A    hubble.yourdomain.com     → <TRAEFIK_IP>

# Atau wildcard:
A    *.yourdomain.com          → <TRAEFIK_IP>
```

**Verify:**
```bash
dig jenkins.yourdomain.com +short
# Harus return TRAEFIK_IP
```

---

## Phase 12: Deploy Jenkins

```bash
kubectl apply -f jenkins/manifests/

# Monitor
kubectl get pods -n jenkins -w
# Tunggu STATUS = Running (3-5 menit, download plugins)

# Verify TLS
kubectl get certificate -n jenkins
# Ready = True

# Akses: https://jenkins.yourdomain.com
# Username: admin
# Password: admin123 (GANTI SEGERA)
```

---

## Phase 13: Setup Registry Credentials

```bash
# Di VM management, generate docker config
cat ~/capi-sa-key.json | \
  jq -r '{auths: {"asia-southeast2-docker.pkg.dev": {username: "_json_key", password: (. | tostring)}}}' \
  > ~/docker-config.json

# Buat Artifact Registry repo di GCP (jika belum)
gcloud artifacts repositories create docker-repo \
  --repository-format=docker \
  --location=asia-southeast2

# Buat secrets di workload cluster
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

Autoscaler jalan di **management cluster** (karena dia watch MachineDeployments):

```bash
# Switch ke management cluster kubeconfig
export KUBECONFIG=~/.kube/config

# Buat secret berisi workload kubeconfig
kubectl create secret generic management-cluster-kubeconfig \
  --from-file=value=~/workload.kubeconfig

# Deploy autoscaler + machinepool definitions
kubectl apply -f autoscaling/cluster-autoscaler.yaml
kubectl apply -f autoscaling/machinepool.yaml

# Verify
kubectl get pods -l app=cluster-autoscaler
kubectl logs -l app=cluster-autoscaler --tail=20
```

---

## Phase 15: Verify Everything

```bash
export KUBECONFIG=~/workload.kubeconfig

# Nodes
kubectl get nodes -o wide

# All pods healthy
kubectl get pods -A | grep -v Running

# Traefik
kubectl get svc traefik -n traefik

# Jenkins accessible
curl -sI https://jenkins.yourdomain.com | head -5
# HTTP/2 200

# Certificates valid
kubectl get certificates -A

# Autoscaler (di management cluster)
export KUBECONFIG=~/.kube/config
kubectl logs -l app=cluster-autoscaler --tail=5
```

---

## Selesai!

```
✓ Management Cluster  — 1 VM, kubeadm, always-on
✓ Workload Cluster    — 3 CP + 2 Workers, HA
✓ Cilium              — CNI + kube-proxy replacement
✓ Traefik             — Ingress, static IP
✓ cert-manager        — Auto TLS Let's Encrypt
✓ Jenkins             — CI/CD, dynamic agents
✓ Cluster Autoscaler  — Scale 1-10 workers
✓ Hubble              — Network observability
```

---

## Troubleshooting

### CAPI: Machine stuck Provisioning
```bash
export KUBECONFIG=~/.kube/config
kubectl describe gcpmachine <name>
# Cek: quota exceeded? Image not found? Network error?

# GCP quota check
gcloud compute project-info describe --format='get(quotas)'
```

### Workload nodes NotReady
```bash
export KUBECONFIG=~/workload.kubeconfig
kubectl describe node <node>
# Cek: Cilium running? containerd healthy?
kubectl get pods -n kube-system -l app.kubernetes.io/name=cilium
```

### Certificate not issuing
```bash
kubectl get challenges -A
kubectl describe challenge <name>
# Biasanya: DNS belum propagate, HTTP-01 challenge unreachable
# Pastikan firewall allow 80/443 ke worker nodes
```

### Jenkins pod OOMKilled
```bash
kubectl describe pod jenkins-0 -n jenkins
# Naikkan memory limit di statefulset.yaml
# limits.memory: 4Gi → 6Gi
```

### Management VM down
```bash
# Selama VM mati:
# - Workload cluster tetap running (sudah independent)
# - Tapi TIDAK bisa autoscale / self-heal nodes
# - Start VM lagi: gcloud compute instances start fariz-k8s-management-cluster
```
