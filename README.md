# Kubernetes Self-Managed di GCP dengan CAPI

## Arsitektur

```
┌─────────────────────────────────────────────────────┐
│                  Management Cluster                   │
│  (1 node, menjalankan CAPI + Infrastructure Provider)│
│                                                       │
│  ┌─────────────┐  ┌──────────────┐  ┌────────────┐ │
│  │ CAPI Core   │  │ CAPG (GCP)   │  │ Bootstrap  │ │
│  │ Controller  │  │ Provider     │  │ (kubeadm)  │ │
│  └─────────────┘  └──────────────┘  └────────────┘ │
└─────────────────────────────────────────────────────┘
            │
            │ manages
            ▼
┌─────────────────────────────────────────────────────┐
│                  Workload Cluster                     │
│                                                       │
│  ┌──────────────────────────────────────────┐       │
│  │ Control Plane (3 nodes, HA)              │       │
│  │ - kube-apiserver                         │       │
│  │ - etcd                                   │       │
│  │ - kube-controller-manager                │       │
│  │ - kube-scheduler                         │       │
│  └──────────────────────────────────────────┘       │
│                                                       │
│  ┌──────────────────────────────────────────┐       │
│  │ Worker Nodes (autoscaled, min:1 max:10)  │       │
│  │ - Cluster Autoscaler                     │       │
│  │ - Workloads                              │       │
│  └──────────────────────────────────────────┘       │
└─────────────────────────────────────────────────────┘
```

## Prerequisites

1. GCP Project dengan billing enabled
2. Service Account dengan roles:
   - `roles/compute.admin`
   - `roles/iam.serviceAccountUser`
   - `roles/storage.admin`
3. Tools lokal:
   - `gcloud` CLI
   - `kubectl`
   - `clusterctl` (CAPI CLI)
   - `kind` (untuk bootstrap management cluster)

## Quick Start

```bash
# 1. Setup GCP credentials
./scripts/01-setup-gcp.sh

# 2. Bootstrap management cluster (kind)
./scripts/02-bootstrap-management.sh

# 3. Install CAPI + GCP provider
./scripts/03-install-capi.sh

# 4. Deploy workload cluster
kubectl apply -f clusters/workload-cluster.yaml

# 5. Pivot management ke self-hosted (opsional)
./scripts/04-pivot-management.sh
```

## Struktur Folder

```
k8s/
├── README.md
├── clusters/
│   ├── management-cluster.yaml    # Management cluster definition
│   └── workload-cluster.yaml      # Workload cluster dengan autoscaling
├── infrastructure/
│   ├── gcp-credentials.yaml       # GCP service account (template)
│   ├── network.yaml               # VPC, Subnet, Firewall
│   └── machine-templates.yaml     # GCE machine templates
├── autoscaling/
│   ├── cluster-autoscaler.yaml    # Cluster Autoscaler deployment
│   └── machinepool.yaml           # MachinePool for autoscaling
├── addons/
│   ├── cilium.yaml                # Cilium CNI (ClusterResourceSet)
│   ├── cilium-helm-values.yaml    # Cilium Helm values (kube-proxy replacement)
│   ├── cilium-networkpolicies.yaml # Contoh Cilium Network Policies
│   ├── hubble-ingress.yaml        # Hubble UI (observability) Ingress
│   ├── metrics-server.yaml        # Metrics server
│   ├── cloud-provider-gcp.yaml    # GCP cloud provider
│   ├── traefik.yaml               # Traefik Ingress (ClusterResourceSet)
│   ├── traefik-helm-values.yaml   # Traefik Helm values (alternatif)
│   ├── cert-manager.yaml          # cert-manager (ClusterResourceSet)
│   ├── cert-manager-helm-values.yaml  # cert-manager Helm values
│   ├── cert-manager-issuers.yaml  # Let's Encrypt ClusterIssuers
│   └── cert-manager-example.yaml  # Contoh penggunaan + middlewares
├── jenkins/
│   ├── README.md                  # Dokumentasi Jenkins
│   ├── manifests/                 # Kubernetes manifests
│   │   ├── namespace.yaml
│   │   ├── rbac.yaml
│   │   ├── pvc.yaml
│   │   ├── configmap-casc.yaml
│   │   ├── statefulset.yaml
│   │   ├── service.yaml
│   │   ├── ingress.yaml
│   │   └── secrets.yaml
│   ├── helm-values.yaml           # Helm install (alternatif)
│   └── pipelines/
│       ├── Jenkinsfile-example    # Contoh pipeline
│       └── app-manifests/
│           └── deployment.yaml    # Contoh app yang di-deploy
└── scripts/
    ├── 01-setup-gcp.sh
    ├── 02-bootstrap-management.sh
    ├── 03-install-capi.sh
    └── 04-pivot-management.sh
```
