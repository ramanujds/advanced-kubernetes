# Kubernetes Cluster Upgrades and Patch Management

## Why Upgrades Matter

Kubernetes releases a new minor version roughly every 4 months. Each version is supported for about 14 months. Falling behind by 3+ minor versions means:

- No security patches for known CVEs
- Add-ons (CNI, CoreDNS, metrics-server) drift out of compatibility
- Cloud providers stop supporting older versions on managed clusters

**Rule: never skip a minor version.** Upgrade 1.28 → 1.29 → 1.30, not 1.28 → 1.30.

---

## The Upgrade Order (Always)

```text
Control plane → Add-ons → Worker nodes
```

Worker nodes must never be newer than the control plane. The API server tolerates workers one minor version behind (the version skew policy), but not ahead.

---

## Kubeadm Cluster Upgrades (Minikube / Self-Managed)

### Check Current and Available Versions

```bash
# Current cluster version
kubectl version --short

# Available upgrade targets
kubeadm upgrade plan
```

`kubeadm upgrade plan` shows the current version, the latest stable, and whether all components are compatible.

### Step 1 — Pre-Upgrade Checks

```bash
# Confirm cluster health
kubectl get nodes
kubectl get pods -A | grep -v Running | grep -v Completed

# Check etcd health (control plane node)
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint health

# Backup etcd before any upgrade
ETCDCTL_API=3 etcdctl snapshot save /backups/etcd-pre-upgrade-$(date +%Y%m%d).db
```

### Step 2 — Upgrade Control Plane

```bash
# On the control-plane node — update kubeadm first
apt-get update && apt-get install -y kubeadm=1.30.0-00

# Dry-run to preview the plan
kubeadm upgrade plan

# Apply the upgrade (upgrades API server, scheduler, controller-manager, etcd, CoreDNS, kube-proxy)
kubeadm upgrade apply v1.30.0

# Then upgrade kubelet and kubectl on the control-plane node
apt-get install -y kubelet=1.30.0-00 kubectl=1.30.0-00
systemctl daemon-reload && systemctl restart kubelet

# Verify control plane is on new version
kubectl get nodes
```

### Step 3 — Upgrade Worker Nodes (Rolling)

Upgrade one worker node at a time. This is where PodDisruptionBudgets protect your workloads.

```bash
# On the control plane — cordon and drain the first worker
kubectl cordon advanced-k8s-m02
kubectl drain advanced-k8s-m02 \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=60

# On the worker node (SSH in)
apt-get update && apt-get install -y kubeadm=1.30.0-00
kubeadm upgrade node

apt-get install -y kubelet=1.30.0-00 kubectl=1.30.0-00
systemctl daemon-reload && systemctl restart kubelet

# Back on control plane — bring the node back
kubectl uncordon advanced-k8s-m02

# Verify the node upgraded
kubectl get nodes
# NAME              STATUS   VERSION
# advanced-k8s      Ready    v1.30.0   (control plane)
# advanced-k8s-m02  Ready    v1.30.0   (upgraded)
# advanced-k8s-m03  Ready    v1.29.x   (not yet)
# advanced-k8s-m04  Ready    v1.29.x   (not yet)

# Repeat drain → upgrade → uncordon for m03 and m04
```

> **Why drain before upgrade?** Draining evicts all non-daemonset pods, so the kubelet restart during upgrade doesn't interrupt running workloads. Without drain, pods would briefly disappear when kubelet restarts.

### Minikube Upgrade (Training Cluster)

```bash
# Check current profile version
minikube version
minikube profile advanced-k8s

# Upgrade the cluster to a newer Kubernetes version
minikube start --profile=advanced-k8s --kubernetes-version=v1.30.0

# Verify
kubectl version --short
```

---

## GKE Upgrade Strategy

On GKE, the control plane is managed. You do not SSH in or run kubeadm. Instead:

### Control Plane Upgrade (Zero Downtime)

```bash
# Check available versions on the release channel
gcloud container get-server-config --region=us-central1

# Upgrade the master (GKE handles HA — no manual cordon/drain needed)
gcloud container clusters upgrade advanced-k8s \
  --region=us-central1 \
  --master \
  --cluster-version=1.30.3-gke.1969000

# Watch until complete
gcloud container operations list --filter="status=RUNNING"
```

### Node Pool Upgrade (Surge Upgrade)

GKE surge upgrades add a new node, drain the old one, delete it. PDBs are respected.

```bash
# Upgrade node pool after control plane is done
gcloud container clusters upgrade advanced-k8s \
  --region=us-central1 \
  --node-pool=default-pool

# Monitor node pool status
gcloud container node-pools describe default-pool \
  --cluster=advanced-k8s \
  --region=us-central1 \
  --format="value(status)"
```

### GKE Auto-Upgrade

Enable at cluster creation time (recommended for non-production, optional for production):

```bash
gcloud container clusters create advanced-k8s \
  --region=us-central1 \
  --enable-autoupgrade \
  --release-channel=regular       # rapid / regular / stable
```

Release channels handle version selection automatically. `regular` is 2-3 months behind `rapid` — safer for production.

---

## EKS Upgrade Strategy

### Check and Upgrade Control Plane

```bash
# Current version
aws eks describe-cluster \
  --name advanced-k8s \
  --query "cluster.version" \
  --region us-east-1

# Upgrade control plane (takes ~15-20 minutes)
aws eks update-cluster-version \
  --name advanced-k8s \
  --kubernetes-version 1.30 \
  --region us-east-1

# Poll until complete
aws eks describe-update \
  --name advanced-k8s \
  --update-id <update-id> \
  --region us-east-1 \
  --query "update.status"
```

### Upgrade Managed Add-Ons (After Control Plane)

```bash
# Add-ons must be upgraded to versions compatible with the new cluster version
aws eks update-addon \
  --cluster-name advanced-k8s \
  --addon-name coredns \
  --region us-east-1

aws eks update-addon \
  --cluster-name advanced-k8s \
  --addon-name kube-proxy \
  --region us-east-1

aws eks update-addon \
  --cluster-name advanced-k8s \
  --addon-name vpc-cni \
  --region us-east-1
```

### Upgrade Node Group (Rolling, Respects PDB)

```bash
eksctl upgrade nodegroup \
  --cluster=advanced-k8s \
  --name=general-workers \
  --kubernetes-version=1.30 \
  --region=us-east-1
```

eksctl drains one node at a time, waits for PDB to allow eviction, then terminates the node and launches a replacement.

---

## PodDisruptionBudgets — Critical for Upgrades

Without a PDB, a drain can evict all replicas of a service at once. With a PDB, drain is blocked until enough replicas are healthy elsewhere.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: part-inventory-pdb
  namespace: inventory-service
spec:
  minAvailable: 2           # at least 2 pods must remain available during disruption
  selector:
    matchLabels:
      app: part-inventory-service
```

Or use `maxUnavailable`:

```yaml
spec:
  maxUnavailable: 1         # at most 1 pod can be down at any time
  selector:
    matchLabels:
      app: part-inventory-service
```

```bash
# Apply PDB before starting a node drain
kubectl apply -f pdb-inventory.yaml

# Verify PDB status
kubectl get pdb -n inventory-service
# NAME                   MIN-AVAILABLE   MAX-UNAVAILABLE   ALLOWED-DISRUPTIONS   AGE
# part-inventory-pdb     2               N/A               1                     5s
```

**ALLOWED-DISRUPTIONS** tells you how many pods can currently be evicted. If this is 0, drain will wait.

---

## Security Patches — CVE Response

When a CVE is published for Kubernetes or a base image, the response depends on severity:

| Severity | Action | Timeline |
| -------- | ------ | -------- |
| Critical (CVSS 9+) | Patch node OS or upgrade Kubernetes immediately | Within 24-48 hours |
| High (CVSS 7-9) | Schedule patch in next maintenance window | Within 1-2 weeks |
| Medium / Low | Track; include in next planned upgrade | Next quarterly cycle |

### Patching Node OS (Without Upgrading Kubernetes)

When a kernel or OS CVE requires a node restart without a Kubernetes upgrade:

```bash
# Drain the node
kubectl drain advanced-k8s-m02 --ignore-daemonsets --delete-emptydir-data

# SSH into the node and patch
sudo apt-get update && sudo apt-get upgrade -y
sudo reboot

# After reboot, restore to schedulable
kubectl uncordon advanced-k8s-m02
```

### Check Node OS and Kubelet Versions

```bash
# Node OS image and kubelet version
kubectl get nodes -o custom-columns=\
NAME:.metadata.name,\
OS:.status.nodeInfo.osImage,\
KUBELET:.status.nodeInfo.kubeletVersion,\
KERNEL:.status.nodeInfo.kernelVersion
```

---

## Version Skew Policy

Kubernetes supports a limited version difference between components:

| Component pair | Max skew |
| -------------- | -------- |
| kube-apiserver ↔ kubelet | ±2 minor versions |
| kube-apiserver ↔ kube-controller-manager | same version |
| kube-apiserver ↔ kube-scheduler | same version |
| kubectl ↔ kube-apiserver | ±1 minor version |

> Worker nodes can be up to 2 minor versions older than the control plane. This means you can upgrade the control plane first and still have working workers — just upgrade workers within the next cycle.

---

## Upgrade Verification Checklist

Run these after every upgrade step:

```bash
# All nodes on the new version and Ready
kubectl get nodes

# No pods stuck in CrashLoopBackOff or Error
kubectl get pods -A | grep -Ev "Running|Completed"

# System pods healthy
kubectl get pods -n kube-system

# API server responding
kubectl cluster-info

# Check that critical workloads survived
kubectl get pods -n inventory-service
kubectl get pods -n order-service

# Confirm PDB was not violated (DISRUPTIONS-ALLOWED should match pre-upgrade)
kubectl get pdb -A

# etcd health post-upgrade (self-managed only)
ETCDCTL_API=3 etcdctl \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key \
  endpoint status --write-out=table
```

---

## Rollback

Kubernetes does not have a native rollback for cluster upgrades. Prevention is the strategy:

1. **Take an etcd snapshot before every upgrade** — restoring from it reverts the entire cluster state
2. **Test on staging first** — always upgrade a lower environment before production
3. **Upgrade node pools one at a time** — a bad worker upgrade is contained; you can stop mid-way
4. **Keep the previous kubelet package** — rolling back a single node is possible if you kept the old `.deb`/`.rpm`

### Restore etcd Snapshot (Last Resort)

```bash
# Stop the API server (remove from staticPod manifests)
mv /etc/kubernetes/manifests/kube-apiserver.yaml /tmp/

# Restore snapshot
ETCDCTL_API=3 etcdctl snapshot restore /backups/etcd-pre-upgrade-20260524.db \
  --data-dir=/var/lib/etcd-restored

# Swap etcd data dir and restart
# Update etcd static pod manifest to point to /var/lib/etcd-restored
mv /tmp/kube-apiserver.yaml /etc/kubernetes/manifests/
```

> On GKE/EKS: contact cloud support for rollback assistance — you do not have etcd access. This is why staging environments are non-negotiable.

---

## Common Upgrade Issues

| Issue | Symptom | Fix |
| ----- | ------- | --- |
| Drain blocked indefinitely | `kubectl drain` hangs, no progress | Check PDB — `ALLOWED-DISRUPTIONS=0` means no pod can be evicted. Scale up replicas or temporarily relax PDB. |
| Pods stuck `Terminating` after drain | Pods stay `Terminating` for minutes | `kubectl delete pod <name> --force --grace-period=0` only as last resort; investigate why graceful shutdown stalled |
| Node stays `NotReady` after upgrade | Node shows `NotReady` post-restart | Kubelet failed to start — check `systemctl status kubelet` and `journalctl -u kubelet -n 50` |
| Add-on incompatibility (CoreDNS crash) | `coredns` pods crash after control plane upgrade | Upgrade the CoreDNS ConfigMap schema — `kubeadm upgrade apply` handles this for self-managed; on EKS run `aws eks update-addon` |
| Kubectl version mismatch | Unexpected API deprecation warnings | Upgrade `kubectl` to match server version (`kubectl version --short`) |
