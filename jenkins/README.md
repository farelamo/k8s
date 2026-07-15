# Jenkins di Kubernetes

## Arsitektur

```
┌─────────────────────────────────────────────────────────────┐
│                    Workload Cluster                           │
│                                                               │
│  namespace: jenkins                                           │
│  ┌─────────────────────────────────────────────────────────┐ │
│  │                                                           │ │
│  │  ┌──────────────────┐     ┌───────────────────────────┐ │ │
│  │  │ Jenkins Master   │     │  Dynamic Agent Pods       │ │ │
│  │  │ (StatefulSet)    │────▶│  (spawn per build,        │ │ │
│  │  │                  │     │   auto-terminate)          │ │ │
│  │  │ - UI             │     │                           │ │ │
│  │  │ - Scheduler      │     │  ┌─────┐ ┌─────┐ ┌─────┐│ │ │
│  │  │ - Config         │     │  │build│ │build│ │build││ │ │
│  │  └──────────────────┘     │  │ #1  │ │ #2  │ │ #3  ││ │ │
│  │           │                │  └─────┘ └─────┘ └─────┘│ │ │
│  │           │                └───────────────────────────┘ │ │
│  │           ▼                                               │ │
│  │  ┌──────────────────┐                                    │ │
│  │  │ PVC (jenkins-home)│                                    │ │
│  │  │ Persistent Data   │                                    │ │
│  │  └──────────────────┘                                    │ │
│  └─────────────────────────────────────────────────────────┘ │
│                                                               │
│  ┌─────────────────────┐                                     │
│  │ Traefik IngressRoute│── https://jenkins.yourdomain.com    │
│  └─────────────────────┘                                     │
└─────────────────────────────────────────────────────────────┘
```

Jenkins Master running sebagai StatefulSet, agent pods di-spawn dinamis per build
(Kubernetes plugin). Setelah build selesai, agent pod otomatis dihapus — hemat resource.

## Struktur Folder

```
jenkins/
├── README.md
├── manifests/                 # Kubernetes manifests (manual deploy)
│   ├── namespace.yaml
│   ├── rbac.yaml
│   ├── pvc.yaml
│   ├── configmap-casc.yaml
│   ├── statefulset.yaml
│   ├── service.yaml
│   ├── ingress.yaml
│   └── secrets.yaml
├── helm-values.yaml           # Helm install (alternatif)
└── pipelines/
    ├── Jenkinsfile-example    # Contoh pipeline
    └── app-manifests/         # Contoh K8s manifest yang di-deploy Jenkins
        └── deployment.yaml
```

## Install via Manifest (manual)

```bash
kubectl apply -f jenkins/manifests/
```

## Install via Helm (recommended)

```bash
helm repo add jenkins https://charts.jenkins.io
helm install jenkins jenkins/jenkins \
  --namespace jenkins --create-namespace \
  -f jenkins/helm-values.yaml
```

## Post-install

```bash
# Get admin password (jika pakai manifest manual)
kubectl exec -n jenkins jenkins-0 -- cat /var/jenkins_home/secrets/initialAdminPassword

# Verify
kubectl get pods -n jenkins
kubectl get svc -n jenkins
```
