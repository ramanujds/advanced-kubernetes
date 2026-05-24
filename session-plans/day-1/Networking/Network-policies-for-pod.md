# Network Policies for Pod Communication and Security

## The Mental Model

By default, Kubernetes networking is **fully open** — every pod can reach every other pod across all namespaces. NetworkPolicy is the firewall layer that restricts this.

| Without NetworkPolicy | With NetworkPolicy |
| --------------------- | ------------------ |
| Any pod can call any pod | Only explicitly allowed traffic flows |
| Cross-namespace traffic unrestricted | Namespace boundaries are enforced |
| No traffic logging or audit trail | CNI plugins like Calico/Cilium add flow logs |

> NetworkPolicy requires a CNI plugin that supports it (Calico, Cilium, Weave). Kindnet (Minikube default) does NOT enforce NetworkPolicy. For these labs, install Calico on the `advanced-k8s` cluster first.

---

## Install Calico on the advanced-k8s Cluster

```bash
# Start the cluster without the default CNI so Calico takes over
minikube start --nodes=4 --cpus=2 --memory=2048 \
  --driver=docker --profile=advanced-k8s \
  --network-plugin=cni --cni=false

# Install Calico
kubectl apply -f https://raw.githubusercontent.com/projectcalico/calico/v3.27.0/manifests/calico.yaml

# Wait for Calico pods to be ready
kubectl wait --for=condition=ready pod -l k8s-app=calico-node -n kube-system --timeout=120s

# Verify — all nodes should reach Ready
kubectl get nodes
```

> On an existing cluster with Kindnet, you can test NetworkPolicy syntax without enforcement. Label the policies clearly and deploy to a cluster with Calico for actual enforcement.

---

## NetworkPolicy Structure

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: <policy-name>
  namespace: <target-namespace>     # policy applies to pods in this namespace
spec:
  podSelector:                       # which pods this policy applies to
    matchLabels:
      app: <label>
  policyTypes:
    - Ingress                        # restrict incoming traffic
    - Egress                         # restrict outgoing traffic
  ingress:
    - from:                          # who is allowed to send traffic IN
        - podSelector: ...
        - namespaceSelector: ...
        - ipBlock: ...
      ports:
        - protocol: TCP
          port: 8080
  egress:
    - to:                            # where this pod is allowed to send traffic
        - podSelector: ...
      ports:
        - protocol: TCP
          port: 3306
```

**Key rule:** once a NetworkPolicy selects a pod, **all unlisted traffic is denied**. A pod with no NetworkPolicy selecting it has unrestricted traffic. A pod selected by at least one policy only allows traffic explicitly permitted.

---

## The Three Selectors

### podSelector — Match pods by label

```yaml
from:
  - podSelector:
      matchLabels:
        app: part-order-service
```

Allows traffic only from pods labeled `app: part-order-service` in the **same namespace**.

### namespaceSelector — Match pods in a namespace

```yaml
from:
  - namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: order-service
```

Allows traffic from any pod in the `order-service` namespace.

### Combined podSelector + namespaceSelector (AND logic)

When both appear in the **same list item**, they are ANDed — pod must match both:

```yaml
from:
  - namespaceSelector:
      matchLabels:
        kubernetes.io/metadata.name: order-service
    podSelector:
      matchLabels:
        app: part-order-service
```

This is "pod labeled `part-order-service` AND in namespace `order-service`" — the most precise and production-safe form.

When they appear as **separate list items**, they are ORed:

```yaml
from:
  - namespaceSelector:           # OR
      matchLabels:
        kubernetes.io/metadata.name: order-service
  - podSelector:                 # OR
      matchLabels:
        app: part-order-service
```

This is a common source of bugs — accidentally allowing all pods in a namespace OR all pods with a label cluster-wide.

---

## Setup: Label the Namespaces

NetworkPolicy namespaceSelector matches on namespace labels. Add them first:

```bash
kubectl label namespace inventory-service kubernetes.io/metadata.name=inventory-service
kubectl label namespace order-service kubernetes.io/metadata.name=order-service

# Verify
kubectl get namespaces --show-labels
```

> Kubernetes 1.21+ automatically sets `kubernetes.io/metadata.name` on namespaces. If your cluster is older, set it manually.

---

## Example 1 — Default Deny All (Zero Trust Baseline)

The first policy to apply to any production namespace. Denies all ingress and egress until explicitly allowed.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny-all
  namespace: inventory-service
spec:
  podSelector: {}                  # {} selects ALL pods in the namespace
  policyTypes:
    - Ingress
    - Egress
```

```bash
kubectl apply -f default-deny-all.yaml

# Verify — order service can no longer reach inventory
kubectl exec -it netshoot -n inventory-service -- \
  curl -m 3 http://part-inventory-service:8080/api/parts
# curl: (28) Connection timed out — traffic is blocked
```

Apply a default-deny to every namespace. Then add allow policies for exactly the traffic you need.

---

## Example 2 — Allow Order Service to Reach Inventory

Restore the legitimate traffic path: `part-order-service` in namespace `order-service` can call `part-inventory-service` on port 8080.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-order-to-inventory
  namespace: inventory-service
spec:
  podSelector:
    matchLabels:
      app: part-inventory-service
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: order-service
          podSelector:
            matchLabels:
              app: part-order-service
      ports:
        - protocol: TCP
          port: 8080
```

```bash
kubectl apply -f allow-order-to-inventory.yaml

# Traffic is allowed again
kubectl exec -it netshoot -n order-service -- \
  curl -s http://part-inventory-service.inventory-service.svc.cluster.local:8080/api/parts | jq .

# But a rogue pod in another namespace is still blocked
kubectl run rogue --image=nicolaka/netshoot --rm -it --restart=Never -- \
  curl -m 3 http://part-inventory-service.inventory-service:8080/api/parts
# Connection timed out
```

---

## Example 3 — Allow Egress to MySQL Only

Inventory service should only be able to make outbound calls to the MySQL pod on port 3306. All other egress blocked.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: inventory-egress-mysql-only
  namespace: inventory-service
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
    - to:                             # also allow DNS (CoreDNS runs on kube-system)
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
        - protocol: TCP
          port: 53
```

> DNS egress (port 53 to kube-system) is almost always needed — forget it and your service can't resolve any name.

```bash
kubectl apply -f inventory-egress-mysql.yaml

# MySQL connection works
kubectl exec -it <inventory-pod> -n inventory-service -- \
  curl -m 3 telnet://mysql:3306

# External call is blocked
kubectl exec -it <inventory-pod> -n inventory-service -- \
  curl -m 3 https://example.com
# curl: (28) Connection timed out
```

---

## Example 4 — Allow Monitoring (Prometheus Scrape)

Prometheus in a `monitoring` namespace needs to scrape metrics from all services on port 8080 (Spring Actuator).

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-prometheus-scrape
  namespace: inventory-service
spec:
  podSelector:
    matchLabels:
      app: part-inventory-service
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

Apply the same policy to `order-service` namespace. Multiple NetworkPolicies on the same pod are **unioned** (ORed) — traffic is allowed if any policy permits it.

---

## Example 5 — Allow External Traffic via Ingress Controller

Ingress controllers (nginx, Traefik) receive external traffic and forward it to services. The ingress controller pod needs to be permitted by NetworkPolicy.

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-ingress-controller
  namespace: order-service
spec:
  podSelector:
    matchLabels:
      app: part-order-service
  policyTypes:
    - Ingress
  ingress:
    - from:
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: ingress-nginx
          podSelector:
            matchLabels:
              app.kubernetes.io/name: ingress-nginx
      ports:
        - protocol: TCP
          port: 8080
```

---

## Example 6 — ipBlock: Allow External API Calls

When a pod must call an external IP range (e.g., a payment gateway or cloud API):

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: allow-payment-gateway-egress
  namespace: order-service
spec:
  podSelector:
    matchLabels:
      app: part-order-service
  policyTypes:
    - Egress
  egress:
    - to:
        - ipBlock:
            cidr: 203.0.113.0/24          # payment gateway IP range
            except:
              - 203.0.113.100/32          # exclude a specific blocked host
      ports:
        - protocol: TCP
          port: 443
    - to:                                  # DNS always needed
        - namespaceSelector:
            matchLabels:
              kubernetes.io/metadata.name: kube-system
      ports:
        - protocol: UDP
          port: 53
```

---

## Full Security Posture: Inventory Namespace

A production-ready policy set for `inventory-service`:

```bash
# 1. Deny everything first
kubectl apply -f default-deny-all.yaml           # deny all ingress + egress

# 2. Allow only order service in
kubectl apply -f allow-order-to-inventory.yaml   # ingress: order-service → 8080

# 3. Allow only MySQL out
kubectl apply -f inventory-egress-mysql.yaml     # egress: mysql:3306 + DNS:53

# 4. Allow Prometheus to scrape
kubectl apply -f allow-prometheus-scrape.yaml    # ingress: monitoring:prometheus → 8080

# Verify all policies in the namespace
kubectl get networkpolicies -n inventory-service
```

---

## Verification Commands

```bash
# List all NetworkPolicies in a namespace
kubectl get networkpolicies -n inventory-service

# Inspect a specific policy
kubectl describe networkpolicy allow-order-to-inventory -n inventory-service

# Test connectivity (from a debug pod)
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never \
  -n order-service -- curl -m 3 http://part-inventory-service.inventory-service:8080/api/parts

# Test that blocked traffic is indeed blocked
kubectl run netshoot --image=nicolaka/netshoot --rm -it --restart=Never \
  -- curl -m 3 http://part-inventory-service.inventory-service:8080/api/parts
# Should time out (default namespace has no allow rule)

# Calico: view effective policy on a pod (requires calicoctl)
calicoctl get networkpolicy -n inventory-service -o wide
```

---

## Policy Evaluation Flow

```text
Pod receives traffic
        │
        ▼
Is the destination pod selected by any NetworkPolicy?
        │
   NO ──┴──► Allow all traffic (no policy = no restriction)
        │
       YES
        ▼
Does any policy's ingress rule permit this traffic?
        │
   NO ──┴──► DROP (implicit deny)
        │
       YES
        ▼
        Allow
```

Multiple policies on the same pod are **unioned** — if any one policy allows the traffic, it is allowed. There is no "deny override" in standard NetworkPolicy. For explicit deny rules, use Calico's `GlobalNetworkPolicy` with deny actions.

---

## Common Pitfalls

| Pitfall | Symptom | Fix |
| ------- | ------- | --- |
| Forgot DNS egress | Pod can't resolve service names | Add egress to `kube-system` port 53 UDP+TCP |
| podSelector + namespaceSelector as separate items (OR instead of AND) | Allows all pods in namespace OR all pods with label cluster-wide | Put both selectors in the same list item (AND semantics) |
| No NetworkPolicy on source pod | Egress from source is unrestricted even if destination has ingress policy | Apply egress policy to source namespace too |
| CNI doesn't support NetworkPolicy | Policies are created but have no effect | Switch to Calico or Cilium |
| Namespace missing label | namespaceSelector never matches | Run `kubectl label namespace <ns> kubernetes.io/metadata.name=<ns>` |
| Policy applied to wrong namespace | Traffic still blocked or allowed unexpectedly | `kubectl get netpol -A` to see all policies across namespaces |
