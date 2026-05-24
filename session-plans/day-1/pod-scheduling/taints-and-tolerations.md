# Taints and Tolerations

## The Mental Model

| Mechanism | Who acts | What it does |
| --------- | -------- | ------------ |
| Node Affinity | Pod | "I want to run on nodes with these labels" |
| Taint | Node | "I repel pods that don't explicitly accept me" |
| Toleration | Pod | "I accept this node's taint — schedule me here" |

> A taint is a node saying **"stay away"**. A toleration is a pod saying **"I'm allowed in"**.

The key difference from affinity: **taints actively block** pods. Affinity guides placement. Taints enforce exclusion.

---

## Taint Structure

```
key=value:effect
```

All three parts:

- **key** — label-like identifier (e.g. `dedicated`, `node-type`, `env`)
- **value** — optional qualifier (e.g. `database`, `spot`, `dev`)
- **effect** — what happens to pods that don't tolerate it

```bash
# Add a taint
kubectl taint nodes <node-name> key=value:Effect

# Remove a taint (append a dash)
kubectl taint nodes <node-name> key=value:Effect-
```

---

## The Three Taint Effects

### NoSchedule

New pods that don't tolerate the taint are **not scheduled** on this node. Existing pods are **not affected**.

```bash
kubectl taint nodes advanced-k8s-m04 node-type=spot:NoSchedule
```

Result: only pods with a matching toleration land on `m04`. Pods already running there continue normally.

### PreferNoSchedule

Soft version of `NoSchedule`. The scheduler **tries to avoid** placing intolerant pods here but will do so if no other node is available.

```bash
kubectl taint nodes advanced-k8s-m03 disktype=hdd:PreferNoSchedule
```

### NoExecute

The strongest effect. New intolerant pods are not scheduled **and** existing intolerant pods are **evicted**.

```bash
kubectl taint nodes advanced-k8s-m04 maintenance=true:NoExecute
# All pods without the matching toleration are evicted immediately
```

---

## Setup: Taint the Spot Node

```bash
# Taint m04 as a spot node — critical workloads should not land here
kubectl taint nodes advanced-k8s-m04 node-type=spot:NoSchedule

# Verify
kubectl describe node advanced-k8s-m04 | grep Taints
# Taints: node-type=spot:NoSchedule
```

---

## Step 1 — Observe Blocking Behavior

Deploy inventory service without any toleration:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: part-inventory-service
  namespace: inventory-service
spec:
  replicas: 3
  selector:
    matchLabels:
      app: part-inventory-service
  template:
    metadata:
      labels:
        app: part-inventory-service
    spec:
      containers:
        - name: part-inventory-service
          image: ram1uj/part-inventory-service
          ports:
            - containerPort: 8080
```

```bash
kubectl apply -f inventory-no-toleration.yaml
kubectl get pods -n inventory-service -o wide
# All 3 pods land on m02 and m03 — m04 is avoided automatically
```

---

## Step 2 — Add Toleration to Allow Spot Scheduling

Now let the order service (non-critical, async) run on spot nodes too:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: part-order-service
  namespace: order-service
spec:
  replicas: 3
  selector:
    matchLabels:
      app: part-order-service
  template:
    metadata:
      labels:
        app: part-order-service
    spec:
      tolerations:
        - key: "node-type"
          operator: "Equal"
          value: "spot"
          effect: "NoSchedule"
      containers:
        - name: part-order-service
          image: ram1uj/part-order-service
          ports:
            - containerPort: 8080
```

```bash
kubectl apply -f order-with-toleration.yaml
kubectl get pods -n order-service -o wide
# Pods can now land on m02, m03, and m04
```

> Toleration does NOT force the pod onto the tainted node — it only **permits** it. Add node affinity alongside if you want to actively target it.

---

## Toleration Operators

### Equal (default)

Key, value, and effect must all match exactly:

```yaml
tolerations:
  - key: "node-type"
    operator: "Equal"
    value: "spot"
    effect: "NoSchedule"
```

### Exists

Matches any taint with this key, regardless of value:

```yaml
tolerations:
  - key: "node-type"
    operator: "Exists"
    effect: "NoSchedule"
```

### Tolerate all taints (use with extreme caution)

An empty key with `Exists` operator tolerates every taint on any node:

```yaml
tolerations:
  - operator: "Exists"
```

This is used by DaemonSets that must run on every node (e.g. `kube-proxy`, `fluentd`).

---

## NoExecute with tolerationSeconds

Allows a pod to remain on a tainted node for a limited time before being evicted. Used in node failure/drain scenarios.

```yaml
tolerations:
  - key: "node.kubernetes.io/not-ready"
    operator: "Exists"
    effect: "NoExecute"
    tolerationSeconds: 300    # stay up to 5 min, then evict if node stays not-ready
```

Kubernetes automatically adds these two tolerations to every pod:

```
node.kubernetes.io/not-ready:NoExecute    tolerationSeconds=300
node.kubernetes.io/unreachable:NoExecute  tolerationSeconds=300
```

This is why pods survive brief node hiccups but are eventually rescheduled after 5 minutes.

---

## NoExecute Lab — Simulate Node Eviction

```bash
# Taint m02 with NoExecute
kubectl taint nodes advanced-k8s-m02 maintenance=true:NoExecute

# Watch pods get evicted from m02 in real time
kubectl get pods -n inventory-service -o wide -w

# Pods without this toleration are evicted and rescheduled on other nodes
# Pods with the toleration (or tolerationSeconds) remain temporarily
```

```bash
# Remove the taint to restore normal scheduling
kubectl taint nodes advanced-k8s-m02 maintenance=true:NoExecute-

# Uncordon if it was also drained
kubectl uncordon advanced-k8s-m02
```

---

## Production Use Cases

### Dedicated Database Nodes

Taint the node so only DB pods run there:

```bash
kubectl taint nodes advanced-k8s-m03 dedicated=database:NoSchedule
```

Only the MySQL StatefulSet has the toleration — no other workload can land there.

### Control Plane Protection

Kubernetes automatically taints control-plane nodes:

```bash
kubectl describe node advanced-k8s | grep Taints
# node-role.kubernetes.io/control-plane:NoSchedule
```

This is why your pods never schedule on the control-plane node by default.

### Spot / Preemptible Nodes (EKS / GKE)

EKS managed spot node groups are typically tainted:

```
node-type=spot:NoSchedule
```

Critical services have no toleration → never land on spot.
Background workers carry the toleration → can use cheap compute.

### Node Maintenance / Cordon

`kubectl cordon` adds this taint automatically:

```
node.kubernetes.io/unschedulable:NoSchedule
```

`kubectl drain` adds `NoExecute` to evict running pods. Both are taint operations under the hood.

---

## Taint + Affinity Together

Taints block unwanted pods. Affinity attracts desired pods. Use both to dedicate a node:

```yaml
# Node has: kubectl taint nodes advanced-k8s-m03 dedicated=database:NoSchedule
# Node has: kubectl label nodes advanced-k8s-m03 dedicated=database

spec:
  tolerations:
    - key: "dedicated"
      operator: "Equal"
      value: "database"
      effect: "NoSchedule"
  affinity:
    nodeAffinity:
      requiredDuringSchedulingIgnoredDuringExecution:
        nodeSelectorTerms:
          - matchExpressions:
              - key: dedicated
                operator: In
                values:
                  - database
```

Without the toleration: pod is blocked even if affinity matches.
Without the affinity: pod is allowed on the node but might not land there.
With both: pod is guaranteed to land on that dedicated node and nowhere else.

---

## Scheduler Decision Flow

```
Pod created
    │
    ▼
Filter: Does node have taints the pod does NOT tolerate?  ──YES──► Skip node
    │ NO
    ▼
Filter: Does node satisfy required nodeAffinity?           ──NO───► Skip node
    │ YES
    ▼
Filter: Does node satisfy required podAffinity?            ──NO───► Skip node
    │ YES
    ▼
Score: Evaluate preferred affinity, resource fit, spread
    │
    ▼
Bind pod to highest-scoring node
```

---

## Verification Commands

```bash
# See taints on all nodes
kubectl get nodes -o custom-columns=NAME:.metadata.name,TAINTS:.spec.taints

# See tolerations on a running pod
kubectl get pod <pod-name> -n inventory-service -o jsonpath='{.spec.tolerations}' | jq .

# Why is a pod Pending? (taint/toleration mismatch shows here)
kubectl describe pod <pod-name> | grep -A 10 "Events:"
```

---

## Cleanup

```bash
kubectl taint nodes advanced-k8s-m04 node-type=spot:NoSchedule-
kubectl taint nodes advanced-k8s-m03 dedicated=database:NoSchedule-
```
