# Node Selection in Kubernetes

## The Mental Model

By default the scheduler places pods wherever resources are available. Node selection lets you add constraints: "this pod must (or should) land on nodes with these characteristics."

Three mechanisms, in order of increasing power:

| Mechanism | Complexity | Use when |
| --------- | ---------- | -------- |
| `nodeSelector` | Simple key=value | Basic filtering, quick wins |
| `nodeName` | Direct assignment | Debugging only — never production |
| `nodeAffinity` | Expressions + soft rules | Production workloads |

---

## Setup: Label the Nodes

First, check what labels already exist on the cluster:

```bash
kubectl get nodes --show-labels
kubectl get nodes -o wide
```

Expected nodes from the `advanced-k8s` profile:

```
NAME                 STATUS   ROLES
advanced-k8s         Ready    control-plane
advanced-k8s-m02     Ready    <none>
advanced-k8s-m03     Ready    <none>
advanced-k8s-m04     Ready    <none>
```

Add labels to simulate a real environment — disk type and workload role:

```bash
# Simulate SSD vs spinning disk
kubectl label nodes advanced-k8s-m02 disktype=ssd
kubectl label nodes advanced-k8s-m03 disktype=ssd
kubectl label nodes advanced-k8s-m04 disktype=hdd

# Simulate on-demand vs spot
kubectl label nodes advanced-k8s-m02 node-type=on-demand
kubectl label nodes advanced-k8s-m03 node-type=on-demand
kubectl label nodes advanced-k8s-m04 node-type=spot

# Verify
kubectl get nodes --show-labels
kubectl get nodes --label-columns disktype,node-type
```

---

## nodeSelector — Simple Filtering

`nodeSelector` is a map of label key=value pairs. The pod only schedules on nodes that have **all** matching labels.

### Example: Pin inventory-service to SSD nodes

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: part-inventory-service
  namespace: inventory-service
spec:
  replicas: 2
  selector:
    matchLabels:
      app: part-inventory-service
  template:
    metadata:
      labels:
        app: part-inventory-service
    spec:
      nodeSelector:
        disktype: ssd           # only nodes with this label
      containers:
        - name: part-inventory-service
          image: ram1uj/part-inventory-service
          ports:
            - containerPort: 8080
```

```bash
kubectl apply -f node-selector-inventory.yaml

# Verify pods landed on SSD nodes only
kubectl get pods -n inventory-service -o wide
```

Expected: both pods on `advanced-k8s-m02` or `advanced-k8s-m03` (the SSD nodes), never on `m04`.

### Break it intentionally

Change `disktype: ssd` to `disktype: nvme` (no node has this label) and reapply:

```bash
kubectl get pods -n inventory-service
# STATUS: Pending

kubectl describe pod <pod-name> -n inventory-service
# Events: 0/4 nodes are available: 3 node(s) didn't match node selector, 1 node(s) had taint ...
```

Revert to `disktype: ssd` to fix.

---

## nodeName — Direct Assignment (Debug Only)

Bypasses the scheduler entirely. Use only to investigate behavior on a specific node, never in production manifests.

```yaml
spec:
  nodeName: advanced-k8s-m02   # hard-wired, no scheduling logic applied
  containers:
    - name: debug
      image: busybox
      command: ["sleep", "3600"]
```

Problems with `nodeName` in production:

- Pod fails permanently if the named node is down (scheduler cannot rescheduled it)
- Ignores taints, resource checks, affinity rules
- Makes manifests environment-specific

---

## Built-In Node Labels

Kubernetes automatically attaches these labels to every node — use them in selectors without adding anything manually:

```bash
kubectl get nodes -o json | jq '.items[].metadata.labels' | grep -E "kubernetes.io|topology"
```

| Label | Example value | Use case |
| ----- | ------------- | -------- |
| `kubernetes.io/hostname` | `advanced-k8s-m02` | Pin to specific node |
| `kubernetes.io/os` | `linux` | OS filtering |
| `kubernetes.io/arch` | `amd64` / `arm64` | Architecture (M1/M2 Mac) |
| `topology.kubernetes.io/zone` | `us-east-1a` | AZ-aware scheduling (cloud) |
| `topology.kubernetes.io/region` | `us-east-1` | Region filtering |
| `node.kubernetes.io/instance-type` | `t3.medium` | Instance type (EKS/GKE) |

---

## Cleanup

```bash
# Remove custom labels
kubectl label nodes advanced-k8s-m02 disktype- node-type-
kubectl label nodes advanced-k8s-m03 disktype- node-type-
kubectl label nodes advanced-k8s-m04 disktype- node-type-
```

---

## nodeSelector vs Node Affinity

`nodeSelector` is syntactic sugar for `required nodeAffinity` with the `In` operator. Under the hood Kubernetes converts it.

```yaml
# nodeSelector version
nodeSelector:
  disktype: ssd

# Equivalent nodeAffinity version
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: disktype
              operator: In
              values:
                - ssd
```

Use `nodeSelector` for simple single-label cases. Switch to `nodeAffinity` when you need:

- Multiple operators (`NotIn`, `Exists`, `Gt`, `Lt`)
- OR logic across label terms
- Soft preferences (preferred scheduling)

See [node-affinity.md](node-affinity.md) for the full story.
