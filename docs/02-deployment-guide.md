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

## PENTING: Kubeconfig Context

Semua command dijalankan dari **management VM** (`fariz-k8s-management-cluster`).
Yang membedakan target cluster adalah **KUBECONFIG**:

```bash
# ┌─────────────────────────────────────────────────────────────────┐
# │ TARGET: MANAGEMENT CLUSTER                                       │
# │ Untuk: CAPI, Cluster Autoscaler, manage workload cluster         │
# │                                                                   │
# │   export KUBECONFIG=$HOME/.kube/config                            │
# │   (atau unset KUBECONFIG)                                         │
# └─────────────────────────────────────────────────────────────────┘

# ┌─────────────────────────────────────────────────────────────────┐
# │ TARGET: WORKLOAD CLUSTER                                         │
# │ Untuk: Cilium, Traefik, cert-manager, Jenkins, Apps              │
# │                                                                   │
# │   export KUBECONFIG=$HOME/workload.kubeconfig                     │
# └─────────────────────────────────────────────────────────────────┘
```

**Cek selalu sebelum jalankan command:**
```bash
echo $KUBECONFIG
kubectl config current-context
```

| Phase | Target Cluster | KUBECONFIG |
|-------|---------------|------------|
| 1-2 | - | Dari laptop/Cloud Shell |
| 3-6 | Management | `$HOME/.kube/config` |
| 7 | - | gcloud (buat image) |
| 8 | - | gcloud (reserve IP) |
| 9 | Management | `$HOME/.kube/config` (apply CAPI manifest) |
| 10-12 | **Workload** | `$HOME/workload.kubeconfig` |
| 13 | **Workload** | `$HOME/workload.kubeconfig` |
| 14 | Management | `$HOME/.kube/config` (autoscaler) |
| 15 | Keduanya | Switch sesuai kebutuhan |

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
sudo apt-get install -y apt-transport-https ca-certificates curl \
  conntrack socat ebtables ipset ipvsadm ethtool

# Kernel modules
cat <<EOF | sudo tee /etc/modules-load.d/k8s.conf
overlay
br_netfilter
ip_vs
ip_vs_rr
ip_vs_wrr
ip_vs_sh
nf_conntrack
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

# VERIFY — pastikan semua ada sebelum buat image!
which kubeadm && which conntrack && which socat && echo "ALL OK"
sudo kubeadm init --dry-run 2>&1 | grep "\[ERROR" || echo "PREFLIGHT PASSED"

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

> ⚠️ **SEMUA command Phase 10-13 target WORKLOAD CLUSTER!**

```bash
# SWITCH KE WORKLOAD CLUSTER
export KUBECONFIG=$HOME/workload.kubeconfig

# Verify kamu di cluster yang benar
kubectl config current-context
kubectl get nodes
# Harus tampil workload nodes, BUKAN management node
```

### 10a. Cilium (CNI + kube-proxy replacement)

```bash
# PENTING: Gunakan internal IP dari CP node, BUKAN LB external IP
# Cek IP CP node:
kubectl get nodes -o wide
# Catat INTERNAL-IP dari control-plane node

CP_INTERNAL_IP="10.88.18.XX"  # Ganti dengan IP CP dari output di atas

helm repo add cilium https://helm.cilium.io/
helm install cilium cilium/cilium \
  --namespace kube-system \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost="${CP_INTERNAL_IP}" \
  --set k8sServicePort=6443 \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList="{10.244.0.0/16}" \
  --set ipam.operator.clusterPoolIPv4MaskSize=24 \
  --set hubble.enabled=true \
  --set hubble.relay.enabled=true \
  --set hubble.ui.enabled=true \
  --set bpf.masquerade=true \
  --set operator.replicas=1

# Tunggu Cilium ready
kubectl get pods -n kube-system -l k8s-app=cilium -w
# Tunggu semua 1/1 Running

# Remove taints yang block scheduling
kubectl taint nodes --all node.cluster.x-k8s.io/uninitialized- 2>/dev/null || true
kubectl taint nodes --all node.cloudprovider.kubernetes.io/uninitialized- 2>/dev/null || true

kubectl get nodes
# Semua harus Ready
```

### 10b. Cloud Provider GCP (CCM)

CCM (Cloud Controller Manager) yang menjembatani cluster dengan GCP API. Fungsinya:

- **cloud-node-controller**: baca metadata VM GCP → populate `INTERNAL-IP`, `EXTERNAL-IP`, zone, region ke Node object. Menghapus taint `node.cloudprovider.kubernetes.io/uninitialized` sehingga workload bisa scheduled.
- **cloud-node-lifecycle-controller**: hapus Node object jika VM sudah dihapus di GCP.
- **service-lb-controller**: provisioning GCP LoadBalancer (Target Pool + Forwarding Rule) otomatis saat ada `Service type: LoadBalancer`.

**Deploy CCM ke workload cluster (via CAPI ClusterResourceSet dari management cluster):**

Deployment CCM di-manage lewat `ClusterResourceSet` CAPI. File-nya sudah include:
- ServiceAccount + ClusterRole + ClusterRoleBinding
- RoleBinding ke built-in `extension-apiserver-authentication-reader` (biar CCM bisa baca request-header CA)
- DaemonSet CCM (jalan di control-plane node)

```bash
# SWITCH KE MANAGEMENT CLUSTER
export KUBECONFIG=$HOME/.kube/config

# Apply — CAPI otomatis push manifest ini ke workload cluster
kubectl apply -f addons/cloud-provider-gcp.yaml

# Verify CRS terbaca CAPI
kubectl get clusterresourceset
kubectl describe clusterresourceset cloud-provider-gcp-crs
```

**Verify CCM jalan di workload cluster:**

```bash
export KUBECONFIG=$HOME/workload.kubeconfig

# CCM DaemonSet harus muncul (jalan di CP node saja)
kubectl get ds -n kube-system cloud-controller-manager

# Pod harus Running
kubectl get pods -n kube-system -l component=cloud-controller-manager

# Cek log — pastikan tiga controller start dan tidak crash
kubectl logs -n kube-system -l component=cloud-controller-manager --tail=30
# Cari log seperti:
#   Started "service-lb-controller"
#   Started "cloud-node-controller"
#   Started "cloud-node-lifecycle-controller"
```

**Efek setelah CCM Running:**

```bash
# Nodes langsung dapat IP + zone label
kubectl get nodes -o wide
# INTERNAL-IP dan EXTERNAL-IP harus terisi, bukan <none>

# Taint uninitialized harus hilang
kubectl describe nodes | grep Taints
# Tidak boleh ada node.cloudprovider.kubernetes.io/uninitialized
```

Jika CCM crash / stuck, lihat section **Troubleshooting → CCM Issues** di bawah.

### 10c. Metrics Server

```bash
kubectl apply -f addons/metrics-server.yaml
```

### 10d. Traefik

> ⚠️ **PENTING**: Pastikan `traefik-helm-values.yaml` **TIDAK** ada annotation `cloud.google.com/l4-rbs: "enabled"`.
> Lihat section **Design Decisions → Kenapa Target Pool, bukan RBS** untuk penjelasan.

```bash
helm repo add traefik https://traefik.github.io/charts
helm install traefik traefik/traefik \
  --namespace traefik --create-namespace \
  -f addons/traefik-helm-values.yaml

# Verify pods running
kubectl get pods -n traefik
# Harus Running

# Setelah 30-60 detik, CCM provisioning LoadBalancer di GCP:
kubectl get svc traefik -n traefik -w
# Tunggu sampai EXTERNAL-IP keluar (bukan <pending>)
# Contoh: 34.101.46.134
```

Jika `EXTERNAL-IP` stuck di `<pending>` >2 menit, lihat section
**Troubleshooting → LoadBalancer stuck pending**.

### 10e. cert-manager

```bash
helm repo add jetstack https://charts.jetstack.io
helm install cert-manager jetstack/cert-manager \
  --namespace cert-manager --create-namespace \
  --set crds.enabled=true

kubectl wait --for=condition=Available deployment --all -n cert-manager --timeout=120s

export ACME_EMAIL="admin@pcsindonesia.com"  # ganti dengan email real
envsubst < addons/cert-manager-issuers.yaml | kubectl apply -f -
```

### 10f. Storage (untuk Jenkins PVC)

```bash
# Buat StorageClass + PV (hostPath, karena belum ada GCP CSI driver)
cat <<'EOF' | kubectl apply -f -
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: standard
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
provisioner: kubernetes.io/no-provisioner
volumeBindingMode: Immediate
---
apiVersion: v1
kind: PersistentVolume
metadata:
  name: jenkins-local-pv
spec:
  capacity:
    storage: 50Gi
  accessModes:
  - ReadWriteOnce
  storageClassName: standard
  persistentVolumeReclaimPolicy: Retain
  hostPath:
    path: /mnt/jenkins-data
    type: DirectoryOrCreate
  claimRef:
    namespace: jenkins
    name: jenkins-home
EOF
```

---

## Phase 11: Setup DNS

**Ambil External IP Traefik:**
```bash
export KUBECONFIG=$HOME/workload.kubeconfig
kubectl get svc traefik -n traefik -o jsonpath='{.status.loadBalancer.ingress[0].ip}'
```

**Buat A record di Cloudflare** (atau DNS provider lain):

| Type | Name | Content | Proxy |
|------|------|---------|-------|
| A | `jenkins-fariz` | `<TRAEFIK_EXTERNAL_IP>` | DNS only (grey cloud) |

> **Kenapa DNS only (grey cloud)**: cert-manager pakai HTTP-01 challenge (default).
> Cloudflare proxy on = HTTP-01 gagal karena traffic ke-intercept Cloudflare.
> Untuk enable proxy on, harus switch ke DNS-01 challenge (butuh API token Cloudflare
> dan konfigurasi tambahan di cert-manager).

**Verify DNS propagate:**
```bash
dig jenkins-fariz.pcsindonesia.com +short
# Harus return IP yang sama dengan Traefik External IP
```

---

## Phase 12: Deploy Jenkins

> ⚠️ **Pastikan masih pakai WORKLOAD kubeconfig!** `echo $KUBECONFIG` → harus `workload.kubeconfig`

```bash
# Buat PVC yang bind ke PV dari Phase 10f
cat <<'EOF' | kubectl apply -f -
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: jenkins-home
  namespace: jenkins
  labels:
    app.kubernetes.io/name: jenkins
spec:
  accessModes:
  - ReadWriteOnce
  storageClassName: standard
  volumeName: jenkins-local-pv
  resources:
    requests:
      storage: 50Gi
EOF

# Verify PVC Bound
kubectl get pvc -n jenkins
# STATUS harus: Bound

# Deploy Jenkins
kubectl apply -f jenkins/manifests/

kubectl get pods -n jenkins -w
# Tunggu Running (3-5 menit, download plugins)

# Test akses (setelah DNS propagate dan cert issued)
curl -v https://jenkins-fariz.pcsindonesia.com
# Sertifikat auto-issued oleh cert-manager (1-2 menit setelah DNS ready)

# Cek status certificate
kubectl get certificate -n jenkins
kubectl describe certificate jenkins-tls -n jenkins
# READY: True → siap dipakai

# Buka browser: https://jenkins-fariz.pcsindonesia.com
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

> ⚠️ **SWITCH KE MANAGEMENT CLUSTER!** Autoscaler jalan di management, bukan workload.

```bash
# SWITCH KE MANAGEMENT CLUSTER
export KUBECONFIG=$HOME/.kube/config

# Verify
kubectl config current-context
# Harus management context

kubectl create secret generic management-cluster-kubeconfig \
  --from-file=value=$HOME/workload.kubeconfig \
  --namespace=kube-system

kubectl apply -k autoscaling/base/

# PENTING: Autoscaler pakai in-cluster config (management).
# Hapus --kubeconfig flag jika ada, biar baca CAPI resources dari management:
kubectl set args deployment/cluster-autoscaler -n kube-system -- \
  --cloud-provider=clusterapi \
  --namespace=default \
  --scale-down-enabled=true \
  --scale-down-delay-after-add=5m \
  --scale-down-unneeded-time=5m \
  --scale-down-utilization-threshold=0.5 \
  --max-node-provision-time=15m \
  --balance-similar-node-groups=true \
  --skip-nodes-with-local-storage=false \
  --expander=least-waste \
  --v=4

# Verify
kubectl get pods -n kube-system -l app=cluster-autoscaler
# Harus 1/1 Running

kubectl logs -n kube-system -l app=cluster-autoscaler --tail=10
# Harus ada: "discovered node group: MachineDeployment/default/fariz-workload-cluster-..."
```

---

## Phase 15: Akses Jenkins

Dengan CCM aktif, Traefik service otomatis dapat External IP. Akses via
`https://jenkins-fariz.pcsindonesia.com` setelah DNS + cert siap.

```bash
export KUBECONFIG=$HOME/workload.kubeconfig

# Verify External IP Traefik
kubectl get svc traefik -n traefik
# EXTERNAL-IP harus terisi (bukan <pending>)

# Verify certificate sudah issued
kubectl get certificate -n jenkins
# READY: True

# Test dari luar
curl -v https://jenkins-fariz.pcsindonesia.com

# Buka browser: https://jenkins-fariz.pcsindonesia.com
# Username: admin / Password: admin123 (GANTI SEGERA!)
```

**Kalau ada masalah**: lihat section **Troubleshooting** di bawah.

---

### Fallback: Akses via SSH Tunnel (untuk debug)

Berguna kalau LB belum ready atau debug internal traffic:

```bash
# Dari laptop
gcloud compute ssh fariz-workload-cluster-workers-6lrvx-dw8bp \
  --zone=asia-southeast2-a \
  --tunnel-through-iap \
  -- -L 8080:localhost:30236

# Buka: http://localhost:8080
```

---

## Phase 16: Verify Everything

```bash
# Management cluster
export KUBECONFIG=$HOME/.kube/config
kubectl get pods -n kube-system -l app=cluster-autoscaler  # Running
kubectl get machines                                         # All Running/Provisioned

# Workload cluster
export KUBECONFIG=$HOME/workload.kubeconfig
kubectl get nodes -o wide                                    # All Ready
kubectl get pods -A | grep -v Running                        # No stuck pods
kubectl get pods -n traefik                                  # Traefik Running
kubectl get pods -n jenkins                                  # Jenkins Running
kubectl get pods -n cert-manager                             # cert-manager Running
kubectl get pods -n kube-system -l k8s-app=cilium            # Cilium Running
kubectl get svc traefik -n traefik                           # NodePort active
kubectl get certificates -A                                  # TLS status
```

---

## Done!

```
✓ Management Cluster  — 1 VM (e2-medium, 30GB), kubeadm, always-on
✓ Workload Cluster    — 3 CP (HA) + 1-10 Workers autoscaled (e2-medium, 30GB)
✓ Cilium              — CNI + kube-proxy replacement (cluster-pool IPAM)
✓ CCM (cloud-provider-gcp) — Auto LoadBalancer + node initialization
✓ Traefik             — Ingress with auto-provisioned GCP LoadBalancer
✓ cert-manager        — Auto TLS Let's Encrypt (HTTP-01 challenge)
✓ Jenkins             — CI/CD, dynamic agents
✓ Cluster Autoscaler  — Running, detected node groups (min 1, max 10)
✓ Hubble              — Network observability

⚠️  TODO (improvement nanti):
- GCP PD CSI Driver → dynamic PVC provisioning (sekarang pakai hostPath)
- External-DNS (auto Cloudflare A record management)
- Prometheus + Grafana stack (observability)
- Backup strategy (Velero)
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

### CCM Issues

**Pod CCM CrashLoopBackOff:**
```bash
export KUBECONFIG=$HOME/workload.kubeconfig
kubectl logs -n kube-system -l component=cloud-controller-manager --tail=50

# Error umum:
# 1. "configmaps extension-apiserver-authentication is forbidden"
#    → Cek RoleBinding "cloud-controller-manager:apiserver-authentication-reader" ada
# 2. "unknown flag" atau help text tercetak
#    → Args CCM tidak valid, cek addons/cloud-provider-gcp.yaml
# 3. "image can't be pulled"
#    → Image tag salah. Pastikan registry.k8s.io/cloud-provider-gcp/cloud-controller-manager:v32.2.5
```

**CCM Running tapi node masih `<none>` IP:**
```bash
# Force restart DaemonSet
kubectl rollout restart daemonset cloud-controller-manager -n kube-system

# Cek CCM bisa nemuin VM di GCP
kubectl logs -n kube-system -l component=cloud-controller-manager | grep -i "searching\|zone"
# Node name harus match dengan VM name di GCP:
gcloud compute instances list --filter="name~fariz-workload"
```

### LoadBalancer stuck `<pending>`

**1. Cek CCM Running:**
```bash
kubectl get pods -n kube-system -l component=cloud-controller-manager
```

**2. Cek error di CCM logs:**
```bash
kubectl logs -n kube-system -l component=cloud-controller-manager --tail=50 | grep -iE "error|failed"
```

**3. Jika error "implemented by alternate to cloud provider":**

Ini artinya service punya annotation/finalizer/forwarding-rule yang bikin CCM ngira ini butuh RBS controller (yang ga ada di cluster self-managed). Cek:

```bash
# Cek annotation RBS
kubectl get svc traefik -n traefik -o yaml | grep -i rbs
# Kalau ada "cloud.google.com/l4-rbs: enabled", hapus:
kubectl annotate svc traefik -n traefik cloud.google.com/l4-rbs-

# Cek finalizer
kubectl get svc traefik -n traefik -o yaml | grep -i finalizer
# NetLBFinalizerV2/V3 → hapus manual

# Cek forwarding rule leftover di GCP
gcloud compute forwarding-rules list --filter="region:asia-southeast2"
# Kalau ada yang punya BackendService (bukan targetPool), hapus:
# gcloud compute forwarding-rules delete <NAME> --region=asia-southeast2
```

**4. Cek target pool health di GCP:**
```bash
gcloud compute target-pools list --regions=asia-southeast2
gcloud compute target-pools get-health <POOL_NAME> --region=asia-southeast2
```

---

## Design Decisions

### Kenapa Target Pool, bukan RBS?

GCP punya dua cara provisioning External LoadBalancer:

**1. Legacy — Target Pool based (dipakai di setup ini)**
- Di-handle langsung oleh CCM
- Resource GCP yang dibikin: Target Pool + Forwarding Rule + Firewall Rule
- Simple, dumb TCP forwarding

**2. Modern — Regional Backend Service (RBS) based**
- Di-handle oleh `l4-netlb-controller` (bagian dari `ingress-gce`)
- Resource GCP: Backend Service + NEG + Forwarding Rule
- Support fitur canggih: custom health check, session affinity granular, NEG-based backend

**Kenapa pilih Target Pool untuk setup ini:**

**1. Cluster self-managed, bukan GKE**

`l4-netlb-controller` otomatis ada di GKE managed, tapi **tidak** otomatis ada di cluster CAPI self-managed. Kalau mau pakai RBS, harus deploy `ingress-gce` sendiri — setup panjang: `glbc` binary + Konnectivity + IAM tambahan + ConfigMap cluster identity + tune reconcile loop.

**2. Traefik jadi single ingress = cuma butuh satu LB**

Semua traffic HTTPS masuk lewat Traefik. Aplikasi lain expose via IngressRoute, ga bikin LB sendiri. Cluster cuma butuh **satu** external LB. Fitur canggih RBS (NEG, custom HC, session affinity granular) semua di-handle Traefik di L7, ga kepake dari sisi LB.

**3. Multi-cloud portability**

Setup ini di-desain multi-cloud (AWS, GCP, Alibaba). Legacy path punya karakteristik yang konsisten di semua cloud:

| Cloud   | Legacy LB Path           |
|---------|--------------------------|
| GCP     | Target Pool              |
| AWS     | Classic Load Balancer    |
| Alibaba | Classic Load Balancer    |

Semua di-handle langsung oleh CCM masing-masing, tanpa controller tambahan. Manifest Kubernetes-nya identik (`type: LoadBalancer` doang, tanpa annotation cloud-specific) di setiap cloud.

**4. Skala ga butuh RBS**

Batas legacy Target Pool: 1000 backend VM per pool. Cluster ini max 10 worker per pool (configured di `MachineDeployment`). Jauh dari batasan. Kalau nanti butuh 1000+ node, pattern-nya bukan "scale up 1 cluster", tapi "banyak cluster" (multi-cluster architecture) — dan setiap cluster tetap cuma butuh 1 LB.

**Trade-off legacy vs RBS:**

| Aspect                    | Legacy Target Pool     | RBS (via ingress-gce)         |
|---------------------------|------------------------|-------------------------------|
| Setup effort              | Zero (built-in CCM)    | Tinggi (deploy controller)    |
| Max backend               | 1000 VM                | Praktis unlimited             |
| Health check custom       | ❌ (GCP default)       | ✅ (custom port, path, dll)   |
| Session affinity granular | ❌ (None / ClientIP)   | ✅ (cookie-based, dll)        |
| NEG-based backend         | ❌ (traffic via node)  | ✅ (langsung ke pod IP)       |
| Dual-stack IPv6           | ❌                     | ✅                            |
| Portability multi-cloud   | ✅ (pattern universal) | ❌ (GCP-specific)             |

**Kapan pertimbangkan migrasi ke RBS:**

- Cluster individual scale >500 node (approaching Target Pool limit)
- Butuh session affinity berbasis cookie (bukan L7 Traefik)
- Butuh direct pod-to-LB routing (skip node hop) untuk latency critical
- Cluster khusus GCP, bukan multi-cloud

Migrasi legacy → RBS sifatnya reversible dan **tidak menghilangkan data** (LB stateless). Downtime bisa dihindari dengan pattern dual-LB + static IP reserved terpisah dari LB technology.

### Kenapa Cilium, bukan Calico/Flannel?

- eBPF-based → performance lebih baik, ga bergantung iptables
- kube-proxy replacement built-in → satu binary lebih sedikit
- Hubble untuk observability
- Portable di semua cloud (jalan di AWS, GCP, Alibaba, on-prem)

### Kenapa Cloudflare untuk DNS, bukan Cloud DNS?

- Portable — 1 DNS provider untuk semua cluster di semua cloud
- Free tier bagus buat setup awal
- Bisa migrasi antar cloud tanpa update DNS provider
- Kalau nanti butuh CDN/WAF, tinggal enable di Cloudflare

---

## Cleanup / Undeploy

Kalau ingin bongkar semua dan mulai dari nol. **PENTING: Cleanup ini destructive
dan tidak bisa di-undo.** Backup data dulu (misal Jenkins home, PVC, secret) sebelum
jalankan.

### Level 1: Bersihin workload cluster saja (management + infra masih ada)

Delete resource K8s satu per satu (reverse dari deploy):

```bash
export KUBECONFIG=$HOME/workload.kubeconfig

# Delete apps + Jenkins
kubectl delete -f jenkins/manifests/ --ignore-not-found
kubectl delete namespace jenkins --ignore-not-found
kubectl delete namespace production --ignore-not-found
kubectl delete namespace staging --ignore-not-found

# Delete cert-manager
kubectl delete -f addons/cert-manager-issuers.yaml --ignore-not-found
helm uninstall cert-manager -n cert-manager
kubectl delete namespace cert-manager --ignore-not-found

# Delete Traefik (ini juga delete LoadBalancer di GCP secara otomatis)
helm uninstall traefik -n traefik
kubectl delete namespace traefik --ignore-not-found

# Delete Cilium
helm uninstall cilium -n kube-system

# CCM di-manage lewat CRS dari management cluster (jangan delete manual di sini)
```

### Level 2: Delete workload cluster (semua VM GCP ke-clean)

```bash
export KUBECONFIG=$HOME/.kube/config

# Delete Cluster resource — CAPI otomatis delete semua GCPMachine + MachineDeployment + KubeadmControlPlane
kubectl delete -f clusters/fariz-workload-cluster.yaml

# Monitor sampai semua resource gone
kubectl get cluster -w
kubectl get machines -w
# Tunggu semua terhapus (5-10 menit)

# Verify VM GCP sudah kehapus
gcloud compute instances list --filter="name~fariz-workload"
# Harus kosong

# Delete CRS + ConfigMap CCM
kubectl delete -f addons/cloud-provider-gcp.yaml

# Delete autoscaler
kubectl delete -k autoscaling/base/
kubectl delete secret management-cluster-kubeconfig -n kube-system --ignore-not-found

# Cleanup ClusterResourceSetBinding (kalau nyangkut)
kubectl delete clusterresourcesetbinding --all -A --ignore-not-found
```

### Level 3: Delete management cluster + semua infra GCP

```bash
# Dari laptop/Cloud Shell (KUBECONFIG tidak penting lagi)

# Delete management VM
gcloud compute instances delete fariz-k8s-management-cluster --zone=asia-southeast2-a --quiet

# Delete image builder (kalau masih ada)
gcloud compute instances delete fariz-k8s-image-builder --zone=asia-southeast2-a --quiet 2>/dev/null

# Delete image
gcloud compute images delete fariz-k8s-node-v1310 --quiet

# Delete static IP (kalau reserved)
gcloud compute addresses delete fariz-traefik-lb-ip --region=asia-southeast2 --quiet 2>/dev/null

# Delete firewall rules
gcloud compute firewall-rules delete fariz-k8s-allow-ssh --quiet
gcloud compute firewall-rules delete fariz-k8s-allow-lb-healthcheck --quiet
gcloud compute firewall-rules delete fariz-k8s-allow-http --quiet

# Cek orphaned LoadBalancer resources (bekas Traefik service)
gcloud compute forwarding-rules list --filter="region:asia-southeast2"
gcloud compute target-pools list --regions=asia-southeast2
gcloud compute firewall-rules list --filter="name~k8s"
# Delete satu-satu kalau ada leftover

# Delete Artifact Registry (kalau ada)
gcloud artifacts repositories delete docker-repo --location=asia-southeast2 --quiet

# Delete Service Account
gcloud iam service-accounts delete fariz-capi-manager@YOUR_PROJECT_ID.iam.gserviceaccount.com --quiet
```

### Level 4: Bersihin DNS di Cloudflare

Manual di Cloudflare dashboard, atau via API:

```bash
# Contoh via API (butuh CF_API_TOKEN)
curl -X DELETE "https://api.cloudflare.com/client/v4/zones/<ZONE_ID>/dns_records/<RECORD_ID>" \
  -H "Authorization: Bearer $CF_API_TOKEN"
```

Record yang perlu dihapus:
- `jenkins-fariz.pcsindonesia.com` (A record)
- Wildcard atau subdomain lain kalau ada

### Verify Cleanup Selesai

```bash
# Semua VM sudah tidak ada
gcloud compute instances list

# Semua LB/forwarding-rules tidak ada
gcloud compute forwarding-rules list
gcloud compute target-pools list --regions=asia-southeast2
gcloud compute backend-services list

# Firewall rules bersih
gcloud compute firewall-rules list

# Artifact registry bersih
gcloud artifacts repositories list
```

### Cleanup Selective (tanpa delete cluster)

Kalau cuma mau reset satu component (misal Traefik atau CCM), skip semua di atas.
Cukup:

```bash
# Reset Traefik LB
kubectl delete svc traefik -n traefik  # LB di GCP otomatis ke-cleanup
# Reinstall via helm

# Reset CCM
kubectl delete clusterresourcesetbinding fariz-workload-cluster -n default
kubectl delete -f addons/cloud-provider-gcp.yaml
kubectl apply -f addons/cloud-provider-gcp.yaml
```
