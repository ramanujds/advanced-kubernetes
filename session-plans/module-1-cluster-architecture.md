# Module 1: Advanced Kubernetes Cluster Architecture
## Day 1 | 9:30 AM – 12:30 PM

---

## Part A — Cluster Architecture Fundamentals (9:30 AM – 11:00 AM)

### Lecture Notes (45 min)

#### Control Plane Components

| Component | Role |
|---|---|
| **kube-apiserver** | Single entry point for all cluster operations; validates and persists state to etcd |
| **etcd** | Distributed key-value store; source of truth for all cluster state |
| **kube-scheduler** | Watches for unscheduled pods; assigns them to nodes based on resource availability |
| **kube-controller-manager** | Runs reconciliation loops (ReplicaSet, Deployment, Node, ServiceAccount controllers) |

#### Worker Node Components

| Component | Role |
|---|---|
| **kubelet** | Agent on each node; ensures containers described in PodSpec are running |
| **kube-proxy** | Maintains iptables/IPVS rules for Service VIP routing |
| **Container runtime** | Runs containers (containerd, CRI-O) |

#### Single Control Plane vs. HA

```
Single CP failure impact:
  - kubectl commands fail (API Server down)
  - New pods cannot be scheduled
  - Running workloads continue (kubelet is autonomous)
  - State cannot be persisted (etcd down)

HA topology:
  Load Balancer → [API Server 1, API Server 2, API Server 3]
                → [etcd 1, etcd 2, etcd 3]  (Raft quorum: need (n/2)+1 nodes)
```

**Raft quorum rule:** Always use odd numbers — 3 etcd nodes tolerate 1 failure; 5 tolerate 2.

#### Production Cluster Design Checklist

- Separate control-plane and worker node subnets
- Dedicated nodes for control plane (no workload pods)
- etcd on fast local SSD (high IOPS requirement)
- Resource requests on all containers (required for scheduler decisions)
- Upgrade path: control plane first, then workers (one node at a time)

---

### Lab 1.1 — Design and Set Up HA-Ready Cluster (45 min)

**Goal:** Multi-node cluster with verified control-plane components.

#### Setup — Create 3-Node Cluster

```bash
# Using minikube with 3 worker nodes
minikube start \
  --nodes=4 \
  --cpus=2 \
  --memory=2048 \
  --driver=docker \
  --profile=advanced-k8s

# Verify nodes
kubectl get nodes -o wide
```

Expected output:
```
NAME                 STATUS   ROLES           AGE   VERSION
advanced-k8s         Ready    control-plane   ...   v1.x.x
advanced-k8s-m02     Ready    <none>          ...   v1.x.x
advanced-k8s-m03     Ready    <none>          ...   v1.x.x
advanced-k8s-m04     Ready    <none>          ...   v1.x.x
```

#### Phase 1 — Verify Control Plane Health

```bash
# All control plane components in kube-system
kubectl get pods -n kube-system

# Component status (deprecated but still useful for quick check)
kubectl get componentstatuses

# etcd health via API server
kubectl get --raw='/healthz'
kubectl get --raw='/readyz'

# Detailed node info
kubectl describe node advanced-k8s | grep -A 10 "Conditions:"
```

#### Phase 2 — Understand kubelet on Each Node

```bash
# SSH into a worker node (minikube)
minikube ssh -p advanced-k8s -n advanced-k8s-m02

# On the node
systemctl status kubelet
journalctl -u kubelet --no-pager | tail -20
exit
```

#### Phase 3 — HA Readiness Assessment

```bash
# Identify single points of failure
kubectl get pods -n kube-system -o wide | grep -E "etcd|apiserver|scheduler|controller"

# Simulate what happens when control plane is unavailable
# (Observation exercise — do not actually stop it in shared lab)
# - Try: kubectl get pods  → would return error
# - But existing pods would keep running
# - Demonstrate with: kubectl get events --watch
```

**Discussion points:**
- Where is etcd data stored? (`/var/lib/etcd`)
- What breaks immediately vs. what keeps running?
- How would you back up etcd? (`etcdctl snapshot save`)

---

## Part B — Cluster Management & Advanced Features (11:15 AM – 12:30 PM)

### Lecture Notes (30 min)

#### Resource Requests vs. Limits

```
Requests = what the scheduler reserves on a node
Limits   = hard cap enforced at runtime (CPU throttled, memory OOM-killed)

QoS Classes:
  Guaranteed  → requests == limits (highest priority, last evicted)
  Burstable   → requests < limits
  BestEffort  → no requests or limits (evicted first under node pressure)
```

**Best practice:** Always set requests. Set limits for memory; be cautious with CPU limits (throttling hurts latency).

#### Namespaces & Multi-Tenancy

```bash
# Namespace isolation model:
#   - Network: NOT isolated by default (needs NetworkPolicy)
#   - Resources: isolated via ResourceQuota + LimitRange
#   - RBAC: scoped per namespace
#   - DNS: service-name.namespace.svc.cluster.local
```

#### ResourceQuota vs. LimitRange

| Object | Scope | Controls |
|---|---|---|
| `ResourceQuota` | Namespace-wide total | Max total CPU/memory/pods/PVCs in namespace |
| `LimitRange` | Per container/pod defaults | Default requests/limits when not specified |

#### Cluster Upgrades (Safe Procedure)

```bash
# 1. Drain node (evict pods gracefully)
kubectl drain <node-name> --ignore-daemonsets --delete-emptydir-data

# 2. Upgrade kubelet + kubectl on that node (OS package manager)
# 3. Uncordon to allow scheduling again
kubectl uncordon <node-name>

# Control plane MUST be upgraded before workers
# Never skip minor versions (1.27 → 1.28 → 1.29, not 1.27 → 1.29)
```

---

### Lab 1.2 — Configure Cluster for Production (45 min)

**Goal:** Namespaces, resource quotas, limit ranges, service accounts.

#### Phase 1 — Create Namespaces and Resource Configuration

Apply the namespace and quota manifests:

```bash
kubectl apply -f kuberneters-manifests/00-namespaces.yaml
kubectl apply -f kuberneters-manifests/01-resource-quotas.yaml
kubectl apply -f kuberneters-manifests/02-service-accounts.yaml
```

Verify:

```bash
# Check namespaces
kubectl get namespaces | grep -E "inventory|order"

# Check quotas
kubectl describe resourcequota -n inventory-service
kubectl describe resourcequota -n order-service

# Check limit ranges
kubectl describe limitrange -n inventory-service

# Check service accounts
kubectl get serviceaccounts -n inventory-service
kubectl get serviceaccounts -n order-service
```

#### Phase 2 — Test ResourceQuota Enforcement

```bash
# Try to exceed quota — should fail
kubectl run test-quota --image=nginx -n inventory-service \
  --overrides='{"spec":{"containers":[{"name":"test","image":"nginx","resources":{"requests":{"memory":"2Gi","cpu":"3"}}}]}}'

# Expected: Error — exceeded quota
kubectl describe resourcequota inventory-quota -n inventory-service
```

#### Phase 3 — Validate Cross-Namespace Visibility

```bash
# Service accounts are namespace-scoped
kubectl get sa -n inventory-service
kubectl get sa -n order-service

# Labels on namespaces
kubectl get ns --show-labels

# Test: try to get pods across namespaces from default SA (should be denied with RBAC)
kubectl auth can-i get pods --as=system:serviceaccount:order-service:part-order-sa -n inventory-service
```

**Key concept to discuss:** Service discovery DNS format:
```
Within same namespace:    http://part-inventory-service:8080
Cross-namespace:          http://part-inventory-service.inventory-service.svc.cluster.local:8080
```

---

## Key Commands Reference

```bash
# Cluster info
kubectl cluster-info
kubectl get nodes -o wide
kubectl describe node <node-name>

# Component health
kubectl get pods -n kube-system
kubectl get componentstatuses

# Namespace management
kubectl create namespace <name>
kubectl get namespaces --show-labels

# Resource quotas
kubectl describe resourcequota -n <namespace>
kubectl describe limitrange -n <namespace>

# Node drain/uncordon
kubectl drain <node> --ignore-daemonsets --delete-emptydir-data
kubectl uncordon <node>

# etcd backup (reference — not run in lab)
ETCDCTL_API=3 etcdctl snapshot save snapshot.db \
  --endpoints=https://127.0.0.1:2379 \
  --cacert=/etc/kubernetes/pki/etcd/ca.crt \
  --cert=/etc/kubernetes/pki/etcd/server.crt \
  --key=/etc/kubernetes/pki/etcd/server.key
```

---

## Troubleshooting Quick Reference

| Symptom | Check | Fix |
|---|---|---|
| Node `NotReady` | `kubectl describe node` / `journalctl -u kubelet` | Restart kubelet, check disk/memory |
| Pod stuck `Pending` | `kubectl describe pod` → Events section | Check resource quota, node capacity |
| `kubectl` connection refused | `~/.kube/config`, API server pod | Verify kubeconfig context |
| etcd leader election failed | etcd pod logs in kube-system | Check network between control-plane nodes |
| Quota exceeded error | `kubectl describe resourcequota -n <ns>` | Increase quota or delete unused resources |
