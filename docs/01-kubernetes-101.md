# Kubernetes 101 — Dari Nol

## Analoginya Dulu

Bayangkan kamu punya **restoran franchise**.

| Dunia Restoran | Dunia Kubernetes |
|---|---|
| Resep makanan | Docker Image (blueprint app) |
| Satu porsi makanan yang disajikan | Container (app yang running) |
| Satu meja yang melayani tamu | Pod (unit terkecil di K8s) |
| Dapur di satu cabang | Node (satu server/VM) |
| Semua cabang restoran kamu | Cluster (kumpulan nodes) |
| Manajer operasional pusat | Control Plane (otak K8s) |
| Aturan "minimal 3 koki per shift" | Deployment (deklarasi state) |
| Load balancer antar kasir | Service (networking) |

---

## Kenapa Kubernetes Ada?

Dulu: 1 app = 1 server. Mau scale? Beli server baru, setup manual.

Sekarang app dipecah jadi banyak **microservices**. Satu produk bisa punya 20+ service. Manage manual? Gila.

Kubernetes = **sistem yang mengatur container secara otomatis**.

Kamu bilang: "Aku mau app ini running 3 instance, kalau mati restart otomatis, kalau traffic naik tambah instance."

Kubernetes jawab: "Oke, gue yang urus."

---

## Komponen Utama

### 1. Cluster

Cluster = sekumpulan mesin (VM/bare metal) yang bekerja bareng sebagai satu kesatuan.

```
┌─────────────── Cluster ───────────────────┐
│                                            │
│  ┌────────────────┐  ┌────────────────┐   │
│  │  Control Plane │  │  Worker Node 1 │   │
│  │  (otak)        │  │  (pekerja)     │   │
│  └────────────────┘  └────────────────┘   │
│                                            │
│  ┌────────────────┐  ┌────────────────┐   │
│  │  Worker Node 2 │  │  Worker Node 3 │   │
│  │  (pekerja)     │  │  (pekerja)     │   │
│  └────────────────┘  └────────────────┘   │
│                                            │
└────────────────────────────────────────────┘
```

### 2. Control Plane (Master)

Otak dari cluster. Tidak menjalankan app kamu, tugasnya mengatur:

| Komponen | Tugas |
|---|---|
| **API Server** | Pintu masuk semua perintah. `kubectl` ngomong ke sini. |
| **etcd** | Database. Nyimpan semua state cluster. |
| **Scheduler** | Memutuskan pod jalan di node mana. "Node 2 masih kosong, taruh di situ." |
| **Controller Manager** | Memastikan state aktual = state yang kamu minta. "Kamu minta 3 pod, sekarang cuma 2, aku bikin 1 lagi." |

### 3. Worker Node

Mesin yang menjalankan app kamu. Setiap node punya:

| Komponen | Tugas |
|---|---|
| **kubelet** | Agent di setiap node. Terima perintah dari control plane, jalankan pod. |
| **Container Runtime** | Yang benar-benar jalankan container (containerd/CRI-O). |

> **Note:** Di setup kita, kube-proxy tidak dipakai. Cilium (via eBPF) menggantikan
> fungsinya untuk Service routing — lebih cepat dan powerful.

### 4. Pod

Unit terkecil di Kubernetes. Satu pod = 1 atau lebih container yang sharing network dan storage.

99% kasus: 1 pod = 1 container = 1 instance app kamu.

```yaml
# Ini pod paling sederhana
apiVersion: v1
kind: Pod
metadata:
  name: my-app
spec:
  containers:
  - name: app
    image: nginx:latest
    ports:
    - containerPort: 80
```

Tapi kamu **jarang bikin pod langsung**. Biasanya pakai Deployment.

---

## Resource yang Sering Dipakai

### Deployment

"Aku mau 3 instance app ini, kalau ada yang mati, restart otomatis."

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: my-app
spec:
  replicas: 3          # Mau berapa instance
  selector:
    matchLabels:
      app: my-app
  template:            # Template pod-nya
    metadata:
      labels:
        app: my-app
    spec:
      containers:
      - name: app
        image: my-app:v1.0
        ports:
        - containerPort: 3000
```

Kubernetes akan:
- Bikin 3 pod
- Kalau 1 pod mati → otomatis bikin yang baru
- Kalau kamu update image → rolling update (satu per satu diganti, zero downtime)

### Service

Pod punya IP yang berubah-ubah (pod mati, IP hilang). Service = **alamat tetap** untuk akses sekumpulan pods.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: my-app
spec:
  selector:
    app: my-app        # Cari pod yang punya label ini
  ports:
  - port: 80           # Port service
    targetPort: 3000   # Port di container
  type: ClusterIP      # Hanya bisa diakses dari dalam cluster
```

Tipe Service:
- **ClusterIP** — internal only (default)
- **NodePort** — expose di port tertentu di setiap node
- **LoadBalancer** — bikin cloud load balancer (GCP, AWS, dll)

### Ingress / IngressRoute

Mengatur traffic dari luar masuk ke service berdasarkan domain/path.

```
internet → Traefik (Ingress Controller) → Service → Pods
                    |
                    ├─ app.domain.com → app-service
                    ├─ api.domain.com → api-service
                    └─ jenkins.domain.com → jenkins-service
```

### ConfigMap & Secret

- **ConfigMap** — config yang non-sensitif (env vars, config files)
- **Secret** — data sensitif (password, API key, certificates)

```yaml
# ConfigMap
apiVersion: v1
kind: ConfigMap
metadata:
  name: app-config
data:
  DATABASE_HOST: "db.internal"
  LOG_LEVEL: "info"

---
# Secret
apiVersion: v1
kind: Secret
metadata:
  name: app-secrets
type: Opaque
data:
  DATABASE_PASSWORD: cGFzc3dvcmQxMjM=  # base64 encoded
```

### Namespace

Pemisah logis dalam cluster. Kayak folder.

```
cluster/
├── default          # namespace default
├── production       # app production
├── staging          # app staging
├── jenkins          # CI/CD
├── traefik          # ingress controller
├── cert-manager     # TLS certificates
└── kube-system      # komponen system K8s
```

---

## Lifecycle App di Kubernetes

```
1. Developer push code
         │
         ▼
2. Jenkins build → Docker image → push ke Registry
         │
         ▼
3. Jenkins apply manifest ke Kubernetes
         │
         ▼
4. Kubernetes:
   - Pull image dari registry
   - Bikin pods sesuai replicas
   - Register pods ke Service
   - Traefik route traffic ke pods
         │
         ▼
5. App live! User akses via domain
```

---

## Konsep Penting: Declarative vs Imperative

**Imperative** (cara lama):
```bash
# "Lakukan ini step by step"
docker run my-app
docker run my-app
docker run my-app
# Kalau mati? Manual restart
```

**Declarative** (cara Kubernetes):
```yaml
# "Aku mau state-nya seperti ini, kamu yang urus caranya"
spec:
  replicas: 3
```

Kubernetes akan TERUS memastikan state aktual = state yang kamu deklarasikan.
Pod mati? Otomatis bikin baru. Node down? Pindahkan pods ke node lain.

Ini namanya **reconciliation loop** — terus-menerus cek dan fix.

---

## Autoscaling — 2 Level

### Level 1: Pod Autoscaling (HPA)

Scale jumlah pod berdasarkan CPU/memory.

```
Traffic naik → CPU 80% → HPA tambah pod → traffic tersebar → CPU turun
```

### Level 2: Node Autoscaling (Cluster Autoscaler)

Pod butuh resource tapi semua node penuh → Cluster Autoscaler bikin node/VM baru.

```
Pods pending (ga cukup resource) → Cluster Autoscaler → Bikin VM baru di GCP → 
Pod dijadwalkan di node baru → Traffic dilayani
```

Ini yang kita setup pakai **CAPI (Cluster API)** — Cluster Autoscaler minta CAPI
untuk provision VM baru di GCP.

---

## Hubungan Semua Komponen yang Kita Setup

```
┌─────────────────────────────────────────────────────────────┐
│                     FULL PICTURE                              │
│                                                               │
│  User Request                                                 │
│       │                                                       │
│       ▼                                                       │
│  ┌─────────┐     ┌──────────┐     ┌──────────────────┐      │
│  │ DNS     │────▶│ Traefik  │────▶│ Service          │      │
│  │         │     │ (Ingress)│     │ (load balance    │      │
│  └─────────┘     │ + TLS    │     │  antar pods)     │      │
│                   └──────────┘     └──────────────────┘      │
│                        │                    │                  │
│                        │                    ▼                  │
│              cert-manager          ┌──────────────────┐      │
│              (auto TLS)            │ Pods (app kamu)  │      │
│                                    │ ┌───┐ ┌───┐ ┌───┐│      │
│                                    │ │ 1 │ │ 2 │ │ 3 ││      │
│                                    │ └───┘ └───┘ └───┘│      │
│                                    └──────────────────┘      │
│                                             │                 │
│                                    HPA (scale pods)           │
│                                             │                 │
│                              ┌──────────────────────────┐    │
│                              │ Cluster Autoscaler (CAPI) │    │
│                              │ scale nodes/VMs           │    │
│                              └──────────────────────────┘    │
│                                                               │
│  ┌──────────────────────────────────────────────────────┐    │
│  │ Jenkins (di dalam cluster juga)                        │    │
│  │ - Build image                                          │    │
│  │ - Push to registry                                     │    │
│  │ - Deploy ke cluster ini                                │    │
│  └──────────────────────────────────────────────────────┘    │
└─────────────────────────────────────────────────────────────┘
```

---

## kubectl — CLI Tool Utama

```bash
# Lihat semua pods
kubectl get pods

# Lihat pods di namespace tertentu
kubectl get pods -n jenkins

# Lihat detail pod
kubectl describe pod my-app-abc123

# Lihat logs
kubectl logs my-app-abc123

# Masuk ke dalam container (seperti docker exec)
kubectl exec -it my-app-abc123 -- /bin/sh

# Apply manifest
kubectl apply -f deployment.yaml

# Delete resource
kubectl delete -f deployment.yaml

# Lihat semua resource di cluster
kubectl get all --all-namespaces

# Scale manual
kubectl scale deployment my-app --replicas=5

# Lihat events (berguna untuk debugging)
kubectl get events --sort-by='.lastTimestamp'
```

---

## Debugging Flow

Sesuatu error? Ikuti urutan ini:

```
1. kubectl get pods -n <namespace>
   → Lihat STATUS: Running? Pending? CrashLoopBackOff? ImagePullBackOff?

2. kubectl describe pod <pod-name> -n <namespace>
   → Lihat Events di bagian bawah

3. kubectl logs <pod-name> -n <namespace>
   → Lihat logs app

4. kubectl get events -n <namespace> --sort-by='.lastTimestamp'
   → Lihat kronologi error
```

Common errors:
- **ImagePullBackOff** — image tidak ditemukan atau tidak punya akses registry
- **CrashLoopBackOff** — app crash terus-menerus (cek logs)
- **Pending** — tidak ada node yang cukup resource (tunggu autoscaler atau scale manual)
- **OOMKilled** — app kehabisan memory (naikkan limits)

---

## Glossary Singkat

| Term | Artinya |
|---|---|
| **Cluster** | Kumpulan machines yang jadi satu |
| **Node** | Satu machine (VM/server) |
| **Pod** | Unit terkecil, wrapper untuk container |
| **Deployment** | Manage pods: replicas, update strategy |
| **Service** | Alamat tetap untuk akses pods |
| **Ingress** | Route traffic dari luar berdasarkan domain |
| **Namespace** | Pemisah logis (kayak folder) |
| **ConfigMap** | Config non-sensitif |
| **Secret** | Data sensitif |
| **PVC** | Request storage |
| **HPA** | Autoscale pods |
| **DaemonSet** | 1 pod per node (monitoring agent, dll) |
| **StatefulSet** | Untuk app yang butuh stable identity (DB, Jenkins) |
| **CRD** | Custom Resource Definition — extend K8s dengan resource baru |
| **Helm** | Package manager untuk K8s (kayak apt/brew) |
| **CAPI** | Cluster API — manage cluster lifecycle secara deklaratif |
| **CAPG** | CAPI provider untuk GCP |

---

## Relevansi dengan Setup Kita

| Yang kita buat | Kenapa |
|---|---|
| CAPI + CAPG | Manage cluster tanpa GKE, multi-platform ready |
| Cluster Autoscaler | Auto tambah/kurangi VM berdasarkan workload |
| Cilium | CNI + kube-proxy replacement (eBPF, lebih cepat) |
| Hubble | Observability — visualisasi traffic antar pod |
| Traefik | Ingress controller — route traffic, TLS termination |
| cert-manager | Auto generate & renew TLS certificate |
| Jenkins di K8s | CI/CD, build & deploy langsung dari dalam cluster |
| Cloud Provider GCP | Integrasi K8s dengan GCP (load balancer, disk) |
| Metrics Server | Provide CPU/memory metrics untuk HPA |

---

## Next Steps untuk Belajar

1. **Coba lokal dulu** — install `minikube` atau `kind`, deploy nginx
2. **Pahami YAML** — semua di K8s adalah YAML manifest
3. **Main sama kubectl** — get, describe, logs, exec
4. **Deploy app sederhana** — Deployment + Service + Ingress
5. **Baru scale up** — HPA, multi-node, production setup
