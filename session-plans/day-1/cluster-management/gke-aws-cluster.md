# Multi-Node HA Cluster on GKE & EKS

## What Changes, What Stays the Same

---

## The Core Difference: Managed Control Plane

In Minikube or kubeadm you own everything. In GKE and EKS the cloud provider owns and operates the control plane. This removes a large category of operational work.

| Concern | Minikube / kubeadm | GKE | EKS |
| ------- | ------------------ | --- | --- |
| Control plane HA (multi-master) | You configure | Automatic | Automatic |
| etcd backup & restore | You run etcdctl | Not your concern | Not your concern |
| API server load balancer | You provision | Automatic | Automatic |
| Control plane upgrades | You drain & upgrade | One-click or auto | Managed via console/CLI |
| Control plane node access | SSH available | No access | No access |
| Worker node management | Manual or scripted | Node pools | Managed node groups |
| Cluster Autoscaler | You deploy & config | Built-in (GKE Autopilot) or toggle | Add-on, enable per node group |

---

## GKE — Google Kubernetes Engine

### Create a Multi-Zone HA Cluster

```bash
# Regional cluster — control plane and nodes spread across 3 zones automatically
gcloud container clusters create advanced-k8s \
  --region=us-central1 \
  --num-nodes=2 \
  --machine-type=e2-standard-2 \
  --enable-autoscaling \
  --min-nodes=1 \
  --max-nodes=5 \
  --enable-autorepair \
  --enable-autoupgrade \
  --release-channel=regular
```

| Flag | What it does |
| ---- | ------------ |
| `--region` | Creates a regional cluster — 3 control plane replicas across 3 zones |
| `--num-nodes=2` | 2 worker nodes *per zone* = 6 total workers |
| `--enable-autoscaling` | Cluster Autoscaler managed by GKE |
| `--enable-autorepair` | Automatically replaces unhealthy nodes |
| `--enable-autoupgrade` | Nodes upgraded automatically on release channel |
| `--release-channel=regular` | Stable, tested Kubernetes versions (rapid/stable also available) |

> **Zonal vs. Regional:** A zonal cluster has one control plane and is not HA. Always use `--region` for production.

### Verify the GKE Cluster

```bash
# Get credentials into kubeconfig
gcloud container clusters get-credentials advanced-k8s --region=us-central1

# Nodes spread across zones
kubectl get nodes -o wide
kubectl get nodes --label-columns topology.kubernetes.io/zone

# Control plane is managed — no etcd/apiserver pods visible in kube-system
kubectl get pods -n kube-system
```

### Node Pool Management

Node pools are groups of nodes with the same machine type and config. Use them for workload isolation.

```bash
# Add a high-memory node pool for database workloads
gcloud container node-pools create high-memory-pool \
  --cluster=advanced-k8s \
  --region=us-central1 \
  --machine-type=e2-highmem-4 \
  --num-nodes=1 \
  --node-taints=workload=database:NoSchedule

# List node pools
gcloud container node-pools list --cluster=advanced-k8s --region=us-central1

# Resize a node pool
gcloud container clusters resize advanced-k8s \
  --region=us-central1 \
  --node-pool=default-pool \
  --num-nodes=3

# Delete a node pool
gcloud container node-pools delete high-memory-pool \
  --cluster=advanced-k8s \
  --region=us-central1
```

### Upgrade Strategy on GKE

```bash
# Check available versions
gcloud container get-server-config --region=us-central1

# Upgrade control plane (GKE handles HA — no downtime)
gcloud container clusters upgrade advanced-k8s \
  --region=us-central1 \
  --master \
  --cluster-version=1.30.x-gke.xxxx

# Upgrade worker nodes (surge upgrade — new node brought up before old drained)
gcloud container clusters upgrade advanced-k8s \
  --region=us-central1 \
  --node-pool=default-pool
```

GKE surge upgrades provision a new node, drain the old one, then delete it — zero disruption if PodDisruptionBudgets are set correctly.

### etcd on GKE

You have **no access** to etcd. GKE takes continuous backups internally. For application-level disaster recovery, use:

```bash
# Backup all manifests (for config DR — not a replacement for etcd backup)
kubectl get all,configmap,secret,ingress,pvc -A -o yaml > cluster-backup.yaml

# Velero is the standard tool for GKE workload backup
velero backup create full-backup --include-namespaces="*"
```

---

## EKS — Amazon Elastic Kubernetes Service

### Create a Multi-AZ HA Cluster

Using `eksctl` (recommended over console for reproducibility):

```bash
# cluster.yaml
cat <<EOF > cluster.yaml
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: advanced-k8s
  region: us-east-1
  version: "1.30"

availabilityZones:
  - us-east-1a
  - us-east-1b
  - us-east-1c

managedNodeGroups:
  - name: general-workers
    instanceType: t3.medium
    minSize: 1
    maxSize: 5
    desiredCapacity: 2
    availabilityZones:
      - us-east-1a
      - us-east-1b
      - us-east-1c
    iam:
      withAddonPolicies:
        autoScaler: true
        cloudWatch: true

addons:
  - name: vpc-cni
  - name: coredns
  - name: kube-proxy
  - name: aws-ebs-csi-driver
EOF

eksctl create cluster -f cluster.yaml
```

Key points:

- EKS control plane is deployed across **3 AZs automatically**
- Managed node groups handle node replacement and upgrades
- `autoScaler: true` attaches the required IAM policies for Cluster Autoscaler

### Verify the EKS Cluster

```bash
# Update kubeconfig
aws eks update-kubeconfig --name advanced-k8s --region us-east-1

# Nodes across AZs
kubectl get nodes -o wide
kubectl get nodes --label-columns topology.kubernetes.io/zone

# EKS managed add-ons (coredns, kube-proxy, vpc-cni) visible in kube-system
kubectl get pods -n kube-system
```

### Managed Node Group Operations

```bash
# List node groups
eksctl get nodegroup --cluster=advanced-k8s --region=us-east-1

# Scale a node group
eksctl scale nodegroup \
  --cluster=advanced-k8s \
  --name=general-workers \
  --nodes=4 \
  --nodes-min=1 \
  --nodes-max=6 \
  --region=us-east-1

# Add a spot instance node group (cost optimization)
eksctl create nodegroup \
  --cluster=advanced-k8s \
  --name=spot-workers \
  --spot \
  --instance-types=t3.medium,t3.large \
  --nodes=2 \
  --nodes-min=0 \
  --nodes-max=10 \
  --region=us-east-1

# Delete a node group (drains nodes first)
eksctl delete nodegroup \
  --cluster=advanced-k8s \
  --name=spot-workers \
  --region=us-east-1
```

### Upgrade Strategy on EKS

```bash
# Check current version
aws eks describe-cluster --name advanced-k8s --query "cluster.version" --region us-east-1

# Upgrade control plane first (AWS handles HA during upgrade)
aws eks update-cluster-version \
  --name advanced-k8s \
  --kubernetes-version 1.30 \
  --region us-east-1

# Watch upgrade status
aws eks describe-update \
  --name advanced-k8s \
  --update-id <update-id> \
  --region us-east-1

# Upgrade managed add-ons after control plane
aws eks update-addon --cluster-name advanced-k8s --addon-name coredns --region us-east-1
aws eks update-addon --cluster-name advanced-k8s --addon-name kube-proxy --region us-east-1

# Upgrade node group (rolling, respects PDB)
eksctl upgrade nodegroup \
  --cluster=advanced-k8s \
  --name=general-workers \
  --kubernetes-version=1.30 \
  --region=us-east-1
```

### etcd on EKS

Same as GKE — no direct access. Use Velero for workload-level backup:

```bash
# Install Velero with S3 backend
velero install \
  --provider aws \
  --plugins velero/velero-plugin-for-aws:v1.x.x \
  --bucket my-velero-backups \
  --backup-location-config region=us-east-1 \
  --snapshot-location-config region=us-east-1

# Backup
velero backup create full-backup --include-namespaces="*"

# Restore
velero restore create --from-backup full-backup
```

---

## What Stays the Same on Both Platforms

These kubectl operations are **identical** regardless of whether you're on Minikube, GKE, or EKS:

### Node Drain / Cordon / Uncordon

```bash
# Cordon (stop scheduling, keep existing pods)
kubectl cordon <node-name>

# Drain (graceful eviction for maintenance)
kubectl drain <node-name> \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=60

# Restore after maintenance
kubectl uncordon <node-name>
```

> On managed node groups (EKS/GKE), prefer draining via the cloud console/CLI for node upgrades — it integrates with the node group lifecycle. Use kubectl drain for manual interventions only.

### Resource Quotas, LimitRanges, Namespaces

```bash
# Identical across all clusters
kubectl apply -f kuberneters-manifests/00-namespaces.yaml
kubectl apply -f kuberneters-manifests/01-resource-quotas.yaml
kubectl apply -f kuberneters-manifests/02-service-accounts.yaml
```

### HPA and PodDisruptionBudgets

```bash
# HPA works the same — metrics-server is pre-installed on GKE/EKS
kubectl autoscale deployment part-inventory-service \
  --cpu-percent=70 --min=2 --max=10

# PDB — critical for zero-downtime node upgrades
kubectl apply -f - <<EOF
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: part-inventory-pdb
  namespace: inventory-service
spec:
  minAvailable: 2
  selector:
    matchLabels:
      app: part-inventory-service
EOF
```

PDBs are especially important on managed clusters — GKE surge upgrades and EKS managed node group updates respect them.

---

## HA Checklist: Managed Clusters (GKE / EKS)

### Control Plane (handled by cloud — verify, don't configure)

- [x] Multi-AZ control plane — automatic on regional GKE / EKS
- [x] etcd backup — managed internally by cloud provider
- [x] API server load balancer — auto-provisioned
- [ ] Enable private endpoint for API server (security best practice)

### Worker Nodes (your responsibility)

- [ ] Node group spans 3+ AZs
- [ ] Autoscaler enabled and tuned (min/max per node group)
- [ ] Separate node pools for different workload types
- [ ] Spot/preemptible node pool for non-critical workloads (cost saving)
- [ ] `--enable-autorepair` (GKE) or managed node group health checks (EKS)

### Workloads

- [ ] `replicas >= 2` for all production deployments
- [ ] `PodDisruptionBudget` on every critical service
- [ ] `PodAntiAffinity` to spread replicas across AZs
- [ ] `topologySpreadConstraints` for even AZ distribution
- [ ] Resource requests set (required for autoscaler to work correctly)

### Upgrades

- [ ] Never skip minor versions
- [ ] Test upgrade on staging cluster first
- [ ] Upgrade control plane → add-ons → node groups (in that order)
- [ ] Monitor PDB violations during node group rolling upgrade

---

## Anti-Affinity: Spread Pods Across AZs

This applies equally to GKE, EKS, and kubeadm clusters. Ensures no single AZ outage takes down all replicas.

```yaml
# In your Deployment spec.template.spec:
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchLabels:
            app: part-inventory-service
        topologyKey: topology.kubernetes.io/zone
```

Or use the simpler `topologySpreadConstraints` (preferred in Kubernetes 1.19+):

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: part-inventory-service
```

---

## Quick Comparison Summary

| Task | Minikube/kubeadm | GKE | EKS |
| ---- | ---------------- | --- | --- |
| Multi-master setup | `kubeadm init --control-plane-endpoint` | `--region` flag (automatic) | Automatic |
| etcd backup | `etcdctl snapshot save` | Not needed (managed) | Not needed (managed) |
| Add worker node | `minikube node add` / `kubeadm join` | `gcloud container clusters resize` | `eksctl scale nodegroup` |
| Node upgrade | `kubectl drain` → OS upgrade → `uncordon` | `gcloud container clusters upgrade` | `eksctl upgrade nodegroup` |
| Autoscaling | Deploy Cluster Autoscaler manually | Enable flag at cluster creation | Enable via IAM policy + deploy CA |
| Workload backup | Velero (self-managed) | Velero / GKE Backup for GKE | Velero with S3 |
| Node drain | `kubectl drain` (identical) | `kubectl drain` (identical) | `kubectl drain` (identical) |
