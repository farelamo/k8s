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
├── kustomization.yaml             # Root kustomization (kubectl apply -k .)
├── README.md
├── docs/
│   ├── 01-kubernetes-101.md       # Penjelasan K8s dari nol
│   └── 02-deployment-guide.md     # Step-by-step deploy (15 phases)
├── clusters/
│   └── fariz-workload-cluster.yaml  # Workload cluster CAPI manifest
├── infrastructure/
│   ├── gcp-credentials.yaml       # GCP service account (template)
│   ├── network.yaml               # VPC/Subnet reference
│   └── machine-templates.yaml     # GCE machine templates
├── autoscaling/
│   └── base/
│       ├── kustomization.yaml
│       ├── cluster-autoscaler.yaml
│       └── machinedeployment-general.yaml
├── addons/
│   ├── cilium.yaml                # Cilium CNI (ClusterResourceSet)
│   ├── cilium-helm-values.yaml    # Cilium Helm values
│   ├── cilium-networkpolicies.yaml
│   ├── hubble-ingress.yaml        # Hubble UI Ingress
│   ├── cloud-provider-gcp.yaml    # GCP Cloud Controller Manager
│   ├── metrics-server.yaml
│   ├── traefik.yaml               # Traefik (ClusterResourceSet)
│   ├── traefik-helm-values.yaml
│   ├── cert-manager.yaml
│   ├── cert-manager-helm-values.yaml
│   ├── cert-manager-issuers.yaml
│   └── cert-manager-example.yaml
├── jenkins/
│   ├── README.md
│   ├── helm-values.yaml
│   ├── manifests/
│   │   ├── namespace.yaml
│   │   ├── rbac.yaml
│   │   ├── pvc.yaml
│   │   ├── configmap-casc.yaml
│   │   ├── statefulset.yaml
│   │   ├── service.yaml
│   │   ├── ingress.yaml
│   │   └── secrets.yaml
│   └── pipelines/
│       ├── Jenkinsfile-example
│       └── app-manifests/
│           └── deployment.yaml
└── scripts/
    ├── 01-setup-gcp.sh
    ├── 02-bootstrap-management.sh
    ├── 03-install-capi.sh
    └── 04-pivot-management.sh
```

## Quick Start

```bash
# Lihat full deployment guide
cat docs/02-deployment-guide.md

# Apply semua via Kustomize (setelah cluster ready)
kubectl apply -k .
```

