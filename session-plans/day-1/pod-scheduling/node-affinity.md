# Node Affinity

## What It Is

Node Affinity is the production-grade replacement for `nodeSelector`. It uses label expressions on nodes to control where pods are scheduled, with support for:

- Multiple operators (`In`, `NotIn`, `Exists`, `DoesNotExist`, `Gt`, `Lt`)
- OR logic across multiple label terms
- Hard rules (pod stays Pending if not satisfied)
- Soft rules (scheduler prefers but does not require)

> **Mental model:** "Pod chooses the node" — the pod carries the preference, not the node.

---

## The Two Rule Types

```
requiredDuringSchedulingIgnoredDuringExecution   → Hard rule
preferredDuringSchedulingIgnoredDuringExecution  → Soft rule
```

The `IgnoredDuringExecution` suffix means: once scheduled, if a node's labels change, the **pod is not evicted**. It only affects placement decisions.

---

## Setup: Label the Nodes

```bash
# Simulate a realistic multi-node cluster
kubectl label nodes advanced-k8s-m02 disktype=ssd  node-type=on-demand env=prod
kubectl label nodes advanced-k8s-m03 disktype=ssd  node-type=on-demand env=prod
kubectl label nodes advanced-k8s-m04 disktype=hdd  node-type=spot      env=prod

# Verify
kubectl get nodes --label-columns disktype,node-type,env
```

---

## Operators Reference

| Operator | Meaning | Example use |
| -------- | ------- | ----------- |
| `In` | Label value is in the list | `env In [prod, staging]` |
| `NotIn` | Label value is NOT in the list | `node-type NotIn [spot]` |
| `Exists` | Label key exists (any value) | `disktype Exists` |
| `DoesNotExist` | Label key is absent | `gpu DoesNotExist` |
| `Gt` | Label value greater than (numeric string) | `storage-gb Gt 100` |
| `Lt` | Label value less than (numeric string) | `storage-gb Lt 500` |

---

## Example 1 — Hard Rule (Required)

Inventory service requires an SSD node — it must not land on HDD:

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
      affinity:
        nodeAffinity:
          requiredDuringSchedulingIgnoredDuringExecution:
            nodeSelectorTerms:
              - matchExpressions:
                  - key: disktype
                    operator: In
                    values:
                      - ssd
      containers:
        - name: part-inventory-service
          image: ram1uj/part-inventory-service
          ports:
            - containerPort: 8080
```

```bash
kubectl apply -f node-affinity-required.yaml
kubectl get pods -n inventory-service -o wide
# Both pods on m02 or m03 (SSD nodes), never m04
```

### Break it and observe

Change `operator: In` / `values: [ssd]` to `values: [nvme]` — no node has that label:

```bash
kubectl get pods -n inventory-service
# STATUS: Pending

kubectl describe pod <pod-name> -n inventory-service
# 0/4 nodes are available: 3 node(s) didn't match node affinity, 1 node(s) had taint...
```

---

## Example 2 — Soft Rule (Preferred)

Order service prefers on-demand nodes but can fall back to spot if needed:

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: part-order-service
  namespace: order-service
spec:
  replicas: 2
  selector:
    matchLabels:
      app: part-order-service
  template:
    metadata:
      labels:
        app: part-order-service
    spec:
      affinity:
        nodeAffinity:
          preferredDuringSchedulingIgnoredDuringExecution:
            - weight: 80
              preference:
                matchExpressions:
                  - key: node-type
                    operator: In
                    values:
                      - on-demand
            - weight: 20
              preference:
                matchExpressions:
                  - key: disktype
                    operator: In
                    values:
                      - ssd
      containers:
        - name: part-order-service
          image: ram1uj/part-order-service
          ports:
            - containerPort: 8080
```

`weight` ranges from 1–100. The scheduler scores nodes by summing weights of matched preferences — higher score wins. Pod still schedules even if no node matches any preference.

---

## Example 3 — Hard + Soft Combined

A common production pattern: hard constraint for correctness, soft constraint for cost optimization.

```yaml
affinity:
  nodeAffinity:
    requiredDuringSchedulingIgnoredDuringExecution:
      nodeSelectorTerms:
        - matchExpressions:
            - key: env
              operator: In
              values:
                - prod                  # must be a prod node
            - key: node-type
              operator: NotIn
              values:
                - spot                  # must NOT be spot
    preferredDuringSchedulingIgnoredDuringExecution:
      - weight: 100
        preference:
          matchExpressions:
            - key: disktype
              operator: In
              values:
                - ssd                   # prefer SSD, but not mandatory
```

---

## Example 4 — OR Logic with Multiple nodeSelectorTerms

Multiple `nodeSelectorTerms` entries are evaluated with **OR** logic.
Multiple `matchExpressions` within one term are evaluated with **AND** logic.

```yaml
requiredDuringSchedulingIgnoredDuringExecution:
  nodeSelectorTerms:
    - matchExpressions:                 # Term 1 (AND within)
        - key: disktype
          operator: In
          values: [ssd]
        - key: node-type
          operator: In
          values: [on-demand]
    - matchExpressions:                 # Term 2 — OR with Term 1
        - key: disktype
          operator: In
          values: [nvme]
```

Pod schedules on: (SSD AND on-demand) OR (nvme).

---

## Example 5 — Exists Operator

Useful when you want to target any labeled node regardless of value:

```yaml
matchExpressions:
  - key: gpu
    operator: Exists       # any node that has a "gpu" label, regardless of value
```

And the inverse — avoid GPU nodes for non-GPU workloads:

```yaml
matchExpressions:
  - key: gpu
    operator: DoesNotExist
```

---

## Production Pattern: Spot vs On-Demand Cost Optimization

```
Node Group A (on-demand):  node-type=on-demand
Node Group B (spot):       node-type=spot
```

Critical workloads (payment, inventory writes) — hard require on-demand:

```yaml
requiredDuringSchedulingIgnoredDuringExecution:
  nodeSelectorTerms:
    - matchExpressions:
        - key: node-type
          operator: In
          values: [on-demand]
```

Background workers (report generation, async jobs) — prefer spot, tolerate on-demand:

```yaml
preferredDuringSchedulingIgnoredDuringExecution:
  - weight: 100
    preference:
      matchExpressions:
        - key: node-type
          operator: In
          values: [spot]
```

---

## Key Concept: IgnoredDuringExecution

```bash
# Pod is running on m02 which has env=prod
kubectl get pods -o wide

# Remove the label from the node
kubectl label nodes advanced-k8s-m02 env-

# Pod is NOT evicted — it keeps running
kubectl get pods -o wide
```

The rule only applies at scheduling time. To get eviction-on-label-change behavior, use `NoExecute` taints (see [taints-and-tolerations.md](taints-and-tolerations.md)).

---

## Verification Commands

```bash
# See all node labels in columnar format
kubectl get nodes --label-columns disktype,node-type,env

# Check where pods landed
kubectl get pods -o wide -n inventory-service
kubectl get pods -o wide -n order-service

# Inspect scheduling decision
kubectl describe pod <pod-name> -n inventory-service | grep -A 20 "Events:"

# Check node affinity on a running pod
kubectl get pod <pod-name> -n inventory-service -o jsonpath='{.spec.affinity}' | jq .
```

---

## Cleanup

```bash
kubectl label nodes advanced-k8s-m02 disktype- node-type- env-
kubectl label nodes advanced-k8s-m03 disktype- node-type- env-
kubectl label nodes advanced-k8s-m04 disktype- node-type- env-
```
