# Multi-Node Kubernetes Cluster with HA Design
## Day 1 — Lab 1.1 Reference Guide

---

## HA Architecture Overview

### Why Single Control Plane Fails in Production

```
Single Control Plane Failure Impact:
  ✗ kubectl commands fail immediately (API Server unreachable)
  ✗ New pods cannot be scheduled (Scheduler down)
  ✗ Cluster state cannot be persisted (etcd down)
  ✓ Running workloads keep running (kubelet is autonomous)
  ✓ Services continue routing traffic (kube-proxy rules persist)
```

### Production HA Topology

```
                        ┌─────────────────────┐
Clients / CI/CD ──────► │   Load Balancer      │  (HAProxy / cloud LB / kube-vip)
                        └──────┬──────┬────────┘
                               │      │
                    ┌──────────┘      └──────────┐
                    ▼                            ▼
           ┌─────────────┐              ┌─────────────┐
           │ Control Plane│              │ Control Plane│  ... (3 or 5 nodes)
           │  API Server  │              │  API Server  │
           │  Scheduler   │              │  Scheduler   │
           │  Ctrl Mgr    │              │  Ctrl Mgr    │
           │  etcd        │◄────────────►│  etcd        │  (Raft consensus)
           └─────────────┘              └─────────────┘

           ┌──────────┐  ┌──────────┐  ┌──────────┐
           │ Worker 1  │  │ Worker 2  │  │ Worker 3  │  ... (N worker nodes)
           │ kubelet   │  │ kubelet   │  │ kubelet   │
           │ kube-proxy│  │ kube-proxy│  │ kube-proxy│
           └──────────┘  └──────────┘  └──────────┘
```

### etcd Quorum — The Critical Rule

| etcd nodes | Fault tolerance | Minimum needed for quorum |
|-----------|----------------|--------------------------|
| 1         | 0 failures      | 1                        |
| 3         | 1 failure       | 2                        |
| 5         | 2 failures      | 3                        |
| 7         | 3 failures      | 4                        |

**Always use odd numbers.** Even numbers buy no extra fault tolerance and increase write latency.

**Raft quorum formula:** need `(n/2) + 1` nodes alive to elect a leader and accept writes.

---

## Lab Setup: Simulating Multi-Node Cluster with Minikube

> Minikube uses a single control plane node. The steps below create a realistic multi-worker topology for learning purposes. The "True HA" section at the end describes production-grade multi-master setups (kubeadm / managed Kubernetes).

### Prerequisites

| Requirement | Minimum | Recommended |
|-------------|---------|-------------|
| RAM available | 6 GB | 8–12 GB |
| CPUs available | 4 | 6–8 |
| Disk space | 20 GB | 40 GB |
| Container driver | Docker Desktop | Docker Desktop |
| Tools | kubectl, minikube | + k9s, kubectx |

Verify your environment:

```bash
minikube version
kubectl version --client
docker info | grep -E "CPUs|Memory"
```

---

## Step 1: Start the Multi-Node Cluster

```bash
minikube start \
  --nodes=4 \
  --cpus=2 \
  --memory=2048 \
  --driver=docker \
  --profile=advanced-k8s
```

| Flag | Purpose |
|------|---------|
| `--nodes=4` | 1 control-plane + 3 worker nodes |
| `--cpus=2` | 2 vCPUs allocated per node |
| `--memory=2048` | 2 GB RAM per node (8 GB total) |
| `--driver=docker` | Runs nodes as Docker containers |
| `--profile=advanced-k8s` | Isolates this cluster from other minikube profiles |

> **Resource constrained?** Use `--nodes=3 --cpus=2 --memory=1800` as a minimum.

---

## Step 2: Verify Cluster Status

```bash
# All nodes and their roles
kubectl get nodes -o wide

# Expected output:
# NAME                 STATUS   ROLES           AGE   VERSION   INTERNAL-IP
# advanced-k8s         Ready    control-plane   ...   v1.x.x    192.168.x.x
# advanced-k8s-m02     Ready    <none>          ...   v1.x.x    192.168.x.x
# advanced-k8s-m03     Ready    <none>          ...   v1.x.x    192.168.x.x
# advanced-k8s-m04     Ready    <none>          ...   v1.x.x    192.168.x.x
```

```bash
# Control plane component health
kubectl get pods -n kube-system

# Quick cluster health check
kubectl get --raw='/healthz'
kubectl get --raw='/readyz'

# Component status (useful for quick triage)
kubectl get componentstatuses
```

**Key components to confirm running in kube-system:**
- `etcd-advanced-k8s` — cluster state store
- `kube-apiserver-advanced-k8s` — API gateway
- `kube-scheduler-advanced-k8s` — pod placement
- `kube-controller-manager-advanced-k8s` — reconciliation loops
- `coredns-*` — cluster DNS (2 replicas for HA)
- `kube-proxy-*` — one per node (DaemonSet)

---

## Step 3: Inspect Control Plane Components

```bash
# Detailed node conditions (look for MemoryPressure, DiskPressure, PIDPressure)
kubectl describe node advanced-k8s | grep -A 10 "Conditions:"

# Where is etcd data stored?
minikube ssh -p advanced-k8s
  ls /var/lib/minikube/etcd   # or /var/lib/etcd on real clusters
exit

# kubelet status on a worker node
minikube ssh -p advanced-k8s -n advanced-k8s-m02
  systemctl status kubelet
  journalctl -u kubelet --no-pager | tail -20
exit
```

---

## Step 4: HA Readiness Assessment

### Identify Single Points of Failure

```bash
# Where are control plane pods scheduled? (should all be on control-plane node)
kubectl get pods -n kube-system -o wide | grep -E "etcd|apiserver|scheduler|controller"

# How many replicas does CoreDNS have? (should be >=2 for HA)
kubectl get deployment coredns -n kube-system

# DaemonSets run one pod per node — already HA by design
kubectl get daemonset -n kube-system
```

### Simulate Control Plane Unavailability (Observation Exercise)

> Do **not** stop the control plane in a shared lab. Run this as a discussion exercise.

```bash
# What would fail if API server went down:
kubectl get pods          # → "connection refused" or timeout
kubectl scale deployment  # → fails (no API)

# What would KEEP running:
# → All existing pods continue (kubelet operates independently)
# → Services keep routing traffic (kube-proxy rules are in iptables/IPVS)
# → No new scheduling until API server recovers
```

---

## Step 5: Node Management — Drain, Cordon, Uncordon

### Cordoning a Node (stop new scheduling, keep existing pods)

```bash
# Mark node unschedulable
kubectl cordon advanced-k8s-m04

# Verify
kubectl get nodes
# advanced-k8s-m04   Ready,SchedulingDisabled   ...

# Re-enable scheduling
kubectl uncordon advanced-k8s-m04
```

### Draining a Node (graceful workload eviction for maintenance)

```bash
# Drain: evict all pods except DaemonSets
kubectl drain advanced-k8s-m03 \
  --ignore-daemonsets \
  --delete-emptydir-data \
  --grace-period=30

# Verify pods migrated to other nodes
kubectl get pods -o wide -A | grep -v kube-system

# After maintenance — restore node
kubectl uncordon advanced-k8s-m03
```

**What drain does:**
1. Cordons the node (no new pods)
2. Sends `SIGTERM` to each pod (respects `terminationGracePeriodSeconds`)
3. Waits for pods to terminate or grace period expires
4. PodDisruptionBudgets are honoured — drain will block if eviction would violate PDB

---

## Step 6: Scale Nodes Dynamically

```bash
# Add a worker node to the running cluster
minikube node add -p advanced-k8s

# Verify new node joined
kubectl get nodes

# Remove a specific node (free resources)
minikube node delete advanced-k8s-m04 -p advanced-k8s

# Verify removal
kubectl get nodes
```

> In production clusters (kubeadm/EKS/GKE), node scaling is handled by the **Cluster Autoscaler** — automatically adds/removes nodes based on pending pod demand and underutilization.

---

## Step 7: etcd Backup (Reference — Not Run in Lab)

etcd is the single source of truth. A backup before any cluster change is non-negotiable in production.

```bash
# Take a snapshot (run on control plane node)
ETCDCTL_API=3 etcdctl snapshot save /tmp/etcd-snapshot.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key

# Verify snapshot integrity
ETCDCTL_API=3 etcdctl snapshot status /tmp/etcd-snapshot.db --write-out=table

# Restore from snapshot (disaster recovery)
ETCDCTL_API=3 etcdctl snapshot restore /tmp/etcd-snapshot.db \
  --data-dir=/var/lib/etcd-restore
```

**Backup schedule recommendation:** hourly snapshots retained for 24h, daily retained for 30 days.

---

## Step 8: Cluster Lifecycle Management

```bash
# Pause cluster (preserves state, frees host CPU/RAM)
minikube stop -p advanced-k8s

# Resume where you left off
minikube start -p advanced-k8s

# Full teardown (deletes all data)
minikube delete -p advanced-k8s
```

---

## Production HA Design: True Multi-Master Setup

> This section covers what a production cluster looks like beyond Minikube. Use for architecture discussions.

### kubeadm HA Initialization

```bash
# Initialize first control-plane node with a VIP (load balancer endpoint)
kubeadm init \
  --control-plane-endpoint="k8s-api.example.com:6443" \
  --upload-certs \
  --pod-network-cidr=10.244.0.0/16

# Join additional control-plane nodes (using the certificate key from init output)
kubeadm join k8s-api.example.com:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash> \
  --control-plane \
  --certificate-key <cert-key>

# Join worker nodes
kubeadm join k8s-api.example.com:6443 \
  --token <token> \
  --discovery-token-ca-cert-hash sha256:<hash>
```

### HA Design Checklist for Production

**Control Plane**
- [ ] Odd number of control-plane nodes (3 or 5)
- [ ] External load balancer in front of API servers (kube-vip, HAProxy, cloud LB)
- [ ] etcd on dedicated fast SSDs (high IOPS — NVMe preferred)
- [ ] Control-plane nodes tainted to reject workload pods
- [ ] Separate subnet for control-plane nodes

**Worker Nodes**
- [ ] Workers spread across multiple availability zones
- [ ] Node labels and taints for workload isolation (GPU, spot, on-demand)
- [ ] PodDisruptionBudgets set on all critical deployments
- [ ] NodeAffinity / PodAntiAffinity to spread replicas across nodes/AZs

**etcd**
- [ ] Regular automated snapshots (hourly minimum)
- [ ] Snapshots stored off-cluster (S3, GCS, NFS)
- [ ] Tested restore procedure documented and rehearsed
- [ ] etcd on dedicated nodes separate from API server (for large clusters)

**Upgrades**
- [ ] Upgrade control plane before workers
- [ ] Never skip minor versions (1.28 → 1.29, not 1.28 → 1.30)
- [ ] One node at a time — drain → upgrade → uncordon → verify → next

---

## Key Commands Quick Reference

```bash
# Node status and details
kubectl get nodes -o wide
kubectl describe node <node-name>
kubectl top nodes                          # requires metrics-server

# Control plane health
kubectl get pods -n kube-system -o wide
kubectl get --raw='/healthz'
kubectl get componentstatuses

# Node drain workflow
kubectl cordon <node>
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl uncordon <node>

# minikube node management
minikube node add -p advanced-k8s
minikube node delete <node-name> -p advanced-k8s
minikube ssh -p advanced-k8s -n <node-name>

# Cluster profile management
minikube profile list
minikube stop -p advanced-k8s
minikube start -p advanced-k8s
minikube delete -p advanced-k8s
```

---

## Troubleshooting

| Symptom | Where to look | Fix |
|---------|--------------|-----|
| Node stuck `NotReady` | `kubectl describe node` → Conditions; `journalctl -u kubelet` | Restart kubelet; check disk/memory pressure |
| Pod stuck `Pending` | `kubectl describe pod` → Events | Check resource quotas, node capacity, taints |
| `kubectl` connection refused | `~/.kube/config`; API server pod in kube-system | Verify kubeconfig context; check API server pod |
| etcd leader election failed | etcd pod logs in kube-system | Check network between control-plane nodes |
| Drain hangs | PodDisruptionBudget blocking eviction | Review PDB config; use `--disable-eviction` only as last resort |
| Insufficient resources for 4-node cluster | `minikube start` error | Reduce `--memory` or `--nodes`; close other apps |
