# Network Policies — Securing Pod-to-Pod Traffic

## What is a NetworkPolicy?

By default, **all Pods in a Kubernetes cluster can talk to all other Pods** across every namespace. There is no firewall between them. A **NetworkPolicy** is a namespace-scoped resource that defines rules for which Pods are allowed to send or receive traffic — essentially a firewall for Pod-to-Pod and Pod-to-external communication.

> **Important:** NetworkPolicy is enforced by the **CNI plugin**, not by the Kubernetes API server itself. Your cluster must run a CNI that supports it: **Calico**, **Cilium**, **Weave**, or **Antrea**. Docker Desktop's default CNI does **not** enforce NetworkPolicy rules — they apply without error but have no effect.

---

## How NetworkPolicy Works

A NetworkPolicy selects Pods via `podSelector` and then defines:

- **ingress** rules — who is allowed to send traffic *into* the selected Pods
- **egress** rules — who the selected Pods are allowed to send traffic *to*

If a NetworkPolicy selects a Pod, **only traffic explicitly allowed by rules is permitted**. All other traffic is denied. If no NetworkPolicy selects a Pod, all traffic flows freely.

### The "select and restrict" model

```text
No policy selects a Pod  →  all traffic allowed (open)
At least one policy selects a Pod  →  only matching rules allowed (default deny for that direction)
```

---

## NetworkPolicy Selectors

### podSelector — which Pods this policy applies to

```yaml
spec:
  podSelector:
    matchLabels:
      app: part-inventory-service   # applies to these Pods
```

An empty `podSelector: {}` selects **all Pods** in the namespace.

### ingress / egress from/to fields

Each rule can restrict traffic by:

| Selector | Description |
| --- | --- |
| `podSelector` | Pods in the same namespace matching labels |
| `namespaceSelector` | All Pods in namespaces matching labels |
| `podSelector` + `namespaceSelector` | Pods matching labels *and* in namespaces matching labels |
| `ipBlock` | A CIDR range (for external traffic) |

### ports

Restrict which port/protocol is allowed:

```yaml
ports:
  - protocol: TCP
    port: 8080
```

Omitting `ports` means all ports on the matched Pods are allowed.

---

## Policy Types

```yaml
spec:
  policyTypes:
    - Ingress   # this policy controls incoming traffic
    - Egress    # this policy controls outgoing traffic
```

If `policyTypes` is omitted, Kubernetes infers it from what you define:
- Has `ingress` rules → `Ingress` is implied
- Has `egress` rules → `Egress` is implied
- Has neither → only `Ingress` is implied (common footgun — always be explicit)

---

## Common Patterns

### 1. Default Deny All (namespace isolation baseline)

Drops all ingress and egress for every Pod in the namespace. Apply this first, then add explicit allow rules on top.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: default
spec:
  podSelector: {}           # selects all Pods in the namespace
  policyTypes:
    - Ingress
    - Egress
```

### 2. Allow Only Specific Ingress (order service → inventory service)

Allows `part-order-service` to reach `part-inventory-service` on port 8080, and denies all other ingress to the inventory service.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-order-to-inventory
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: part-inventory-service     # policy applies to inventory Pods
  policyTypes:
    - Ingress
  ingress:
    - from:
        - podSelector:
            matchLabels:
              app: part-order-service  # only allow traffic from order-service Pods
      ports:
        - protocol: TCP
          port: 8080
```

### 3. Allow DNS Egress (essential for most workloads)

When you apply a default-deny egress policy, Pods lose DNS resolution. Always add this rule.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-dns-egress
  namespace: default
spec:
  podSelector: {}
  policyTypes:
    - Egress
  egress:
    - ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

### 4. Allow Egress to MySQL StatefulSet

Allows the inventory service to reach MySQL on port 3306 only.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-inventory-to-mysql
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: part-inventory-service
  policyTypes:
    - Egress
  egress:
    - to:
        - podSelector:
            matchLabels:
              app: mysql
      ports:
        - protocol: TCP
          port: 3306
```

### 5. Cross-Namespace Traffic (allow monitoring from another namespace)

Allows a Prometheus Pod in the `monitoring` namespace to scrape metrics from all Pods in `default`.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scrape
  namespace: default
spec:
  podSelector: {}
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: monitoring
          podSelector:
            matchLabels:
              app: prometheus
      ports:
        - protocol: TCP
          port: 8080
```

> **Note:** `namespaceSelector` + `podSelector` in the same `-from` list item means **both** must match (AND logic). Two separate `-from` items means **either** (OR logic).

### 6. Allow External Ingress via CIDR (NodePort / LoadBalancer)

Allows traffic from a specific IP range into the order service (e.g., from an internal corporate network).

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-external-ingress
  namespace: default
spec:
  podSelector:
    matchLabels:
      app: part-order-service
  policyTypes:
    - Ingress
  ingress:
    - from:
        - ipBlock:
            cidr: 10.0.0.0/8          # allow from internal RFC-1918 range
            except:
              - 10.100.0.0/16         # block a specific subnet within that range
      ports:
        - protocol: TCP
          port: 8080
```

---

## AND vs OR in from/to

This is the most common source of confusion:

```yaml
# OR — traffic from monitoring namespace OR from pods labelled role=frontend
from:
  - namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: monitoring
  - podSelector:
      matchLabels:
        role: frontend

# AND — traffic from pods labelled role=frontend AND in the monitoring namespace
from:
  - namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: monitoring
    podSelector:
      matchLabels:
        role: frontend
```

The difference is the `-` dash: separate list items = OR, same item = AND.

---

## Testing Network Policies

```bash
# Launch a test Pod in the same namespace
kubectl run test --image=busybox --restart=Never -- sleep 3600

# Test connectivity to the inventory service
kubectl exec test -- wget -qO- http://part-inventory-service:8080/actuator/health

# Test connectivity to MySQL
kubectl exec test -- nc -zv mysql 3306

# From a different namespace (tests cross-namespace rules)
kubectl run test -n monitoring --image=busybox --restart=Never -- sleep 3600
kubectl exec -n monitoring test -- wget -qO- http://part-inventory-service.default.svc.cluster.local:8080/actuator/health

# Clean up
kubectl delete pod test
kubectl delete pod test -n monitoring
```

---

## Recommended Policy Stack for This Project

Apply in this order:

```bash
kubectl apply -f default-deny-all.yml           # 1. deny everything first
kubectl apply -f allow-dns-egress.yml            # 2. restore DNS
kubectl apply -f allow-order-to-inventory.yml    # 3. order → inventory on 8080
kubectl apply -f allow-inventory-to-mysql.yml    # 4. inventory → mysql on 3306
kubectl apply -f allow-prometheus-scrape.yml     # 5. monitoring namespace scrape (optional)
```

---

## Key Takeaways

- No NetworkPolicy = all traffic flows freely (default open)
- At least one NetworkPolicy selecting a Pod = implicit deny for unmatched traffic in that direction
- Always add a DNS egress allow rule when applying default-deny-egress
- Same `-from` list item = AND logic; separate list items = OR logic
- NetworkPolicy requires a supporting CNI (Calico, Cilium, etc.) — Docker Desktop's CNI does not enforce them
- Apply default-deny-all per namespace, then carve out explicit allows — never the other way around
