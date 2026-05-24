# Pod Affinity and Anti-Affinity

## The Mental Model

Node Affinity answers: "Which **node** should this pod run on?"

Pod Affinity / Anti-Affinity answers: "Which **other pods** should this pod run near — or away from?"

| Type | Meaning | Common use |
| ---- | ------- | ---------- |
| `podAffinity` | Run **together** with matching pods | Co-locate latency-sensitive services |
| `podAntiAffinity` | Run **apart** from matching pods | Spread replicas for HA |

The matching is done against **other pods' labels**, not node labels. The `topologyKey` defines the boundary — "same node", "same zone", etc.

---

## Topology Key — The Boundary of "Together"

```
kubernetes.io/hostname          → same physical node
topology.kubernetes.io/zone     → same availability zone (EKS/GKE)
topology.kubernetes.io/region   → same cloud region
```

On the `advanced-k8s` minikube cluster, only `kubernetes.io/hostname` applies (all nodes are on the same machine). Use `topology.kubernetes.io/zone` examples as the production reference.

---

## The Two Rule Types

Same pattern as node affinity:

```
requiredDuringSchedulingIgnoredDuringExecution   → Hard rule — pod stays Pending if not satisfied
preferredDuringSchedulingIgnoredDuringExecution  → Soft rule — scheduler tries but won't block
```

> **Production tip:** Prefer `preferredDuringScheduling` for anti-affinity. Using `required` anti-affinity with too few nodes causes scheduling deadlocks where replicas can't all be placed.

---

## Example 1 — Pod Affinity: Co-locate Order and Inventory Services

The order service calls inventory service over the network. If they're on the same node, the call stays local — lower latency.

**Step 1 — Deploy inventory service (the target):**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: part-inventory-service
  namespace: inventory-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: part-inventory-service
  template:
    metadata:
      labels:
        app: part-inventory-service
        tier: backend
    spec:
      containers:
        - name: part-inventory-service
          image: ram1uj/part-inventory-service
          ports:
            - containerPort: 8080
```

**Step 2 — Deploy order service with affinity toward inventory:**

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: part-order-service
  namespace: order-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: part-order-service
  template:
    metadata:
      labels:
        app: part-order-service
    spec:
      affinity:
        podAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchExpressions:
                  - key: app
                    operator: In
                    values:
                      - part-inventory-service
              topologyKey: kubernetes.io/hostname
              namespaces:
                - inventory-service       # cross-namespace affinity requires explicit namespace
      containers:
        - name: part-order-service
          image: ram1uj/part-order-service
          ports:
            - containerPort: 8080
```

```bash
kubectl apply -f inventory.yaml
kubectl apply -f order-with-affinity.yaml

# Verify both pods are on the same node
kubectl get pods -o wide -n inventory-service
kubectl get pods -o wide -n order-service
```

**What happens if inventory pod is deleted?**

```bash
kubectl delete deployment part-inventory-service -n inventory-service
kubectl get pods -n order-service
# part-order-service → Pending (required affinity target is gone)
```

---

## Example 2 — Pod Anti-Affinity: Spread Replicas Across Nodes

The most important production pattern. Never let all replicas of a service pile onto one node.

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
      affinity:
        podAntiAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            - labelSelector:
                matchExpressions:
                  - key: app
                    operator: In
                    values:
                      - part-inventory-service
              topologyKey: kubernetes.io/hostname
      containers:
        - name: part-inventory-service
          image: ram1uj/part-inventory-service
          ports:
            - containerPort: 8080
```

```bash
kubectl apply -f inventory-anti-affinity.yaml

# Each replica on a different node
kubectl get pods -n inventory-service -o wide
# pod-1 → advanced-k8s-m02
# pod-2 → advanced-k8s-m03
# pod-3 → advanced-k8s-m04
```

**Try scaling to 4 replicas (only 3 worker nodes):**

```bash
kubectl scale deployment part-inventory-service --replicas=4 -n inventory-service
kubectl get pods -n inventory-service
# 3 Running, 1 Pending — 4th can't be placed (required anti-affinity, no node left)
```

This is the scheduling deadlock — scale back or switch to `preferred`.

---

## Example 3 — Preferred Anti-Affinity (Production Recommended)

Soft anti-affinity avoids the deadlock while still spreading replicas optimally:

```yaml
affinity:
  podAntiAffinity:
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        podAffinityTerm:
          labelSelector:
            matchExpressions:
              - key: app
                operator: In
                values:
                  - part-inventory-service
          topologyKey: kubernetes.io/hostname
```

Behaviour: scheduler strongly prefers different nodes per replica. If forced (e.g. scaling beyond node count), it places multiple replicas on the same node rather than leaving them Pending.

---

## Example 4 — Multi-AZ Spread (Production HA Pattern)

On EKS/GKE with nodes in multiple zones, use the zone topology key to guarantee AZ-level redundancy:

```yaml
affinity:
  podAntiAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      - labelSelector:
          matchExpressions:
            - key: app
              operator: In
              values:
                - part-inventory-service
        topologyKey: topology.kubernetes.io/zone
```

With 3 replicas across 3 AZs (`us-east-1a`, `1b`, `1c`): one AZ failing takes down at most 1 replica.

---

## Modern Alternative: topologySpreadConstraints

Introduced in Kubernetes 1.19, `topologySpreadConstraints` is the **recommended approach** over `podAntiAffinity` for spreading. It gives precise control over how evenly pods are distributed.

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: part-inventory-service
  namespace: inventory-service
spec:
  replicas: 4
  selector:
    matchLabels:
      app: part-inventory-service
  template:
    metadata:
      labels:
        app: part-inventory-service
    spec:
      topologySpreadConstraints:
        - maxSkew: 1                              # max difference in pod count across topology domains
          topologyKey: kubernetes.io/hostname     # spread across nodes
          whenUnsatisfiable: DoNotSchedule        # hard rule (use ScheduleAnyway for soft)
          labelSelector:
            matchLabels:
              app: part-inventory-service
      containers:
        - name: part-inventory-service
          image: ram1uj/part-inventory-service
          ports:
            - containerPort: 8080
```

```bash
kubectl apply -f inventory-spread.yaml

# 4 replicas across 3 nodes: scheduler places 2/1/1 or 2/2/0 (maxSkew=1 allows 1 difference)
kubectl get pods -n inventory-service -o wide
```

### Dual spread: nodes AND zones

```yaml
topologySpreadConstraints:
  - maxSkew: 1
    topologyKey: topology.kubernetes.io/zone     # spread across AZs first
    whenUnsatisfiable: DoNotSchedule
    labelSelector:
      matchLabels:
        app: part-inventory-service
  - maxSkew: 1
    topologyKey: kubernetes.io/hostname          # then spread across nodes within AZ
    whenUnsatisfiable: ScheduleAnyway            # soft — don't block if within-AZ balance isn't perfect
    labelSelector:
      matchLabels:
        app: part-inventory-service
```

### topologySpreadConstraints vs podAntiAffinity

| Feature | `podAntiAffinity` | `topologySpreadConstraints` |
| ------- | ----------------- | --------------------------- |
| Control | Binary (together / apart) | Numeric (max skew across domains) |
| Scheduling cost | High (O(n²) pod comparisons) | Lower |
| Handles uneven node counts | Poorly | Well |
| `whenUnsatisfiable` modes | required / preferred only | `DoNotSchedule` / `ScheduleAnyway` |
| Recommended for spreading | No (legacy) | Yes (Kubernetes 1.19+) |

---

## Lab: Verify Spreading on the Multi-Node Cluster

```bash
# Create 3 replicas with hard anti-affinity
kubectl apply -f inventory-anti-affinity.yaml

# Check distribution
kubectl get pods -n inventory-service -o wide

# Scale up to trigger Pending
kubectl scale deployment part-inventory-service --replicas=5 -n inventory-service
kubectl get pods -n inventory-service
# 3 Running (one per node), 2 Pending

# Switch to topology spread (replace the deployment)
kubectl apply -f inventory-spread.yaml
kubectl get pods -n inventory-service -o wide
# All 5 pods scheduled — spread as evenly as possible
```

---

## Verification Commands

```bash
# Check pod distribution across nodes
kubectl get pods -o wide -n inventory-service

# Inspect affinity config on a pod
kubectl get pod <pod-name> -n inventory-service -o jsonpath='{.spec.affinity}' | jq .

# Inspect topology spread constraints
kubectl get pod <pod-name> -n inventory-service -o jsonpath='{.spec.topologySpreadConstraints}' | jq .

# Why is a pod Pending?
kubectl describe pod <pod-name> -n inventory-service | grep -A 15 "Events:"
# Look for: didn't match pod affinity / anti-affinity rules
```

---

## Common Pitfalls

| Pitfall | Symptom | Fix |
| ------- | ------- | --- |
| Required anti-affinity with replicas > nodes | Extra replicas Pending forever | Switch to `preferred` or use `topologySpreadConstraints` |
| Cross-namespace affinity missing `namespaces` field | Affinity ignored (looks in same namespace only) | Add `namespaces: [target-namespace]` |
| Affinity target deleted | Pods with required affinity go Pending | Use `preferred` for availability, `required` only for strict co-location |
| Wrong `topologyKey` on minikube | All pods land on one node | Use `kubernetes.io/hostname` on minikube, `topology.kubernetes.io/zone` on cloud |
| Complex affinity rules in large clusters | Slow scheduling | Prefer `topologySpreadConstraints` for spreading; avoid O(n²) pod comparisons |
