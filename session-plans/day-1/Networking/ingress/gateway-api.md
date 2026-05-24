# Gateway API

## Why Gateway API Exists

Ingress was designed for simple HTTP routing. As Kubernetes grew into enterprise platforms, its limitations became structural — not fixable with annotations. Gateway API is the SIG-Network answer.

| Problem with Ingress | Gateway API solution |
| -------------------- | -------------------- |
| HTTP/HTTPS only | Supports HTTP, HTTPS, TCP, UDP, gRPC |
| Single monolithic resource | Split into GatewayClass → Gateway → Route |
| Infra + routing in one object | Role-based separation (infra team / app team) |
| Controller-specific annotations | Standardized spec, portable across controllers |
| No native traffic splitting | First-class weighted backends |
| No header manipulation | Built-in request/response modification |

Gateway API is **GA** as of Kubernetes 1.28 for HTTPRoute. It does not replace Ingress immediately — both coexist.

---

## Object Model

```text
GatewayClass   ← cluster-scoped, created by infra team once
    │           defines which controller implements this class
    ▼
Gateway        ← namespace or cluster-scoped
    │           defines listeners (ports, protocols, TLS)
    │           controls which Routes can attach to it
    ▼
HTTPRoute      ← namespace-scoped, created by app team
    │           defines path/host rules, backends, weights
    ▼
Service → Pods
```

### Role Separation in Practice

| Team | Owns | Concerns |
| ---- | ---- | -------- |
| Platform / Infra | `GatewayClass`, `Gateway` | Ports, TLS certificates, allowed namespaces |
| Application | `HTTPRoute`, `GRPCRoute` | Path rules, backends, canary weights |

App teams can deploy routes without touching TLS config or load balancer settings.

---

## Install Gateway API CRDs

Gateway API ships as CRDs — not built into Kubernetes core.

```bash
# Install the standard channel CRDs (HTTPRoute, Gateway, GatewayClass are GA here)
kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.1.0/standard-install.yaml

# Verify CRDs are installed
kubectl get crd | grep gateway.networking.k8s.io
# gatewayclasses.gateway.networking.k8s.io
# gateways.gateway.networking.k8s.io
# httproutes.gateway.networking.k8s.io
```

---

## Setup on advanced-k8s (NGINX Gateway Fabric)

NGINX Gateway Fabric is the open-source Gateway API implementation for NGINX:

```bash
# Install NGINX Gateway Fabric
kubectl apply -f https://raw.githubusercontent.com/nginxinc/nginx-gateway-fabric/v1.3.0/deploy/crds.yaml
kubectl apply -f https://raw.githubusercontent.com/nginxinc/nginx-gateway-fabric/v1.3.0/deploy/default/deploy.yaml

# Verify
kubectl get pods -n nginx-gateway
# NAME                             READY   STATUS
# nginx-gateway-xxxx               2/2     Running

# GatewayClass is created by the controller
kubectl get gatewayclass
# NAME    CONTROLLER                         ACCEPTED
# nginx   gateway.nginx.org/nginx-gateway    True
```

---

## Example 1 — Basic HTTP Routing

Route `/inventory` and `/orders` paths to the respective services.

### Gateway (infra team — created once)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: parts-gateway
  namespace: default
spec:
  gatewayClassName: nginx
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same          # only HTTPRoutes in the same namespace can attach
```

### HTTPRoute (app team — per service)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: inventory-route
  namespace: default
spec:
  parentRefs:
    - name: parts-gateway         # attach to the gateway above
  hostnames:
    - parts.local
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /inventory
      backendRefs:
        - name: part-inventory-service
          port: 80
    - matches:
        - path:
            type: PathPrefix
            value: /orders
      backendRefs:
        - name: part-order-service
          port: 80
```

```bash
kubectl apply -f gateway.yaml
kubectl apply -f httproute.yaml

# Check attachment status
kubectl describe gateway parts-gateway
# Listeners:  http  READY  1 attached routes

kubectl describe httproute inventory-route
# Parents: parts-gateway  Accepted: True  ResolvedRefs: True

# Test
curl http://parts.local/inventory/api/parts
curl http://parts.local/orders/api/part-orders
```

---

## Example 2 — TLS Termination

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: parts-gateway
  namespace: default
spec:
  gatewayClassName: nginx
  listeners:
    - name: https
      port: 443
      protocol: HTTPS
      tls:
        mode: Terminate
        certificateRefs:
          - kind: Secret
            name: parts-tls        # same TLS secret as Ingress
      allowedRoutes:
        namespaces:
          from: Same
    - name: http-redirect
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: Same
```

```yaml
# HTTPRoute to redirect HTTP → HTTPS
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: http-to-https-redirect
  namespace: default
spec:
  parentRefs:
    - name: parts-gateway
      sectionName: http-redirect
  rules:
    - filters:
        - type: RequestRedirect
          requestRedirect:
            scheme: https
            statusCode: 301
```

---

## Example 3 — Traffic Splitting (Canary Releases)

The existing [gateway-api-on-gke/httproute.yaml](gateway-api-on-gke/httproute.yaml) has commented-out weights. This is how you use them for a canary deployment:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: inventory-canary
  namespace: default
spec:
  parentRefs:
    - name: parts-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /inventory
      backendRefs:
        - name: part-inventory-service        # stable (v1)
          port: 80
          weight: 90                          # 90% of traffic
        - name: part-inventory-service-v2     # canary (v2)
          port: 80
          weight: 10                          # 10% of traffic
```

```bash
kubectl apply -f inventory-canary.yaml

# Observe split — roughly 1 in 10 requests hits v2
for i in $(seq 1 20); do
  curl -s http://parts.local/inventory/api/parts | jq .version
done
```

This is native in the spec — no annotations, no controller-specific configuration.

---

## Example 4 — Header-Based Routing

Route internal testers to the canary version using a request header:

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: inventory-header-route
  namespace: default
spec:
  parentRefs:
    - name: parts-gateway
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /inventory
          headers:
            - name: X-Canary
              value: "true"
      backendRefs:
        - name: part-inventory-service-v2    # canary only
          port: 80
    - matches:
        - path:
            type: PathPrefix
            value: /inventory
      backendRefs:
        - name: part-inventory-service       # everyone else
          port: 80
```

```bash
# Regular request → stable
curl http://parts.local/inventory/api/parts

# Canary header → v2
curl -H "X-Canary: true" http://parts.local/inventory/api/parts
```

---

## Example 5 — Request Header Modification

Add upstream headers before forwarding to the backend — useful for tracing or auth propagation:

```yaml
rules:
  - matches:
      - path:
          type: PathPrefix
          value: /inventory
    filters:
      - type: RequestHeaderModifier
        requestHeaderModifier:
          add:
            - name: X-Forwarded-Source
              value: gateway
          remove:
            - X-Internal-Debug
    backendRefs:
      - name: part-inventory-service
        port: 80
```

---

## Example 6 — Multi-Namespace Routes (Cross-Team)

Allow the `order-service` namespace to attach HTTPRoutes to a gateway in a different namespace:

```yaml
# Gateway in 'platform' namespace — allows routes from any namespace
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: shared-gateway
  namespace: platform
spec:
  gatewayClassName: nginx
  listeners:
    - name: http
      port: 80
      protocol: HTTP
      allowedRoutes:
        namespaces:
          from: All             # any namespace can attach routes
```

```yaml
# HTTPRoute in 'order-service' namespace — attaches to the platform gateway
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: order-route
  namespace: order-service
spec:
  parentRefs:
    - name: shared-gateway
      namespace: platform       # cross-namespace reference
  rules:
    - matches:
        - path:
            type: PathPrefix
            value: /orders
      backendRefs:
        - name: part-order-service
          port: 80
```

```bash
# Check attachment from the route side
kubectl describe httproute order-route -n order-service
# Parents:
#   Name: shared-gateway  Namespace: platform  Accepted: True
```

---

## Gateway API on GKE

GKE has first-class support for Gateway API via the GKE Gateway controller, which provisions Google Cloud Load Balancers.

See the existing [gateway-api-on-gke/](gateway-api-on-gke/) manifests — the GatewayClass is `gke-l7-global-external-managed`:

```bash
# Enable Gateway API on GKE (requires GKE 1.24+)
gcloud container clusters update advanced-k8s \
  --gateway-api=standard \
  --region=us-central1

# Verify GatewayClasses created by GKE
kubectl get gatewayclass
# gke-l7-global-external-managed    True   (external HTTPS LB)
# gke-l7-regional-external-managed  True   (regional LB)
# gke-l7-rilb                       True   (internal LB)
```

```bash
# Apply the GKE-specific Gateway and HTTPRoute
kubectl apply -f gateway-api-on-gke/gateway.yaml
kubectl apply -f gateway-api-on-gke/httproute.yaml

# GKE provisions a real HTTPS Load Balancer — takes 3-5 minutes
kubectl get gateway parts-gateway
# NAME            CLASS                              ADDRESS          READY
# parts-gateway   gke-l7-global-external-managed    34.111.xxx.xxx   True
```

The `ADDRESS` is a public IP from Google Cloud — same as GCE Ingress but via the new API.

---

## Verification Commands

```bash
# Status of all Gateways
kubectl get gateway -A

# Status of all HTTPRoutes
kubectl get httproute -A

# Detailed status — check Accepted and ResolvedRefs conditions
kubectl describe gateway parts-gateway
kubectl describe httproute inventory-route

# Common conditions to check
# Accepted: True    → route is attached to the gateway
# ResolvedRefs: True → all backend services exist and are reachable

# Controller logs
kubectl logs -n nginx-gateway -l app=nginx-gateway --tail=50
```

---

## Ingress vs Gateway API — Full Comparison

| Feature | Ingress | Gateway API |
| ------- | ------- | ----------- |
| HTTP/HTTPS routing | Yes | Yes |
| TCP / UDP routing | No | Yes (TCPRoute, UDPRoute) |
| gRPC routing | No | Yes (GRPCRoute) |
| Traffic splitting / canary | Via annotations | Native (`weight`) |
| Header matching | Via annotations | Native |
| Request/response modification | Via annotations | Native (filters) |
| Role separation | No | Yes (Gateway + HTTPRoute) |
| Cross-namespace routing | No | Yes |
| Controller portability | No (annotation lock-in) | Yes (standard spec) |
| Maturity | Stable (GA) | HTTPRoute GA in 1.28 |

---

## Migration Path: Ingress → Gateway API

You do not need to migrate immediately. A staged approach:

1. **Keep existing Ingress** — do not break what works
2. **Install Gateway API CRDs** alongside Ingress
3. **New services** use HTTPRoute from day one
4. **Migrate existing routes** service by service, validate, remove old Ingress rule
5. **Decommission Ingress** when all routes are migrated

Both can coexist in the same cluster on different controllers.

```bash
# You can have both simultaneously
kubectl get ingress -A      # old routes
kubectl get httproute -A    # new routes
```

---

## Common Pitfalls

| Pitfall | Symptom | Fix |
| ------- | ------- | --- |
| CRDs not installed | `no matches for kind "HTTPRoute"` | Install standard-install.yaml first |
| GatewayClass not accepted | Gateway stays in `Unknown` state | Check controller is running and GatewayClass name matches |
| Route not attaching | `Accepted: False` in HTTPRoute status | Namespace selector on Gateway may block the route's namespace |
| Backend not resolved | `ResolvedRefs: False` | Service name/port mismatch; check `kubectl get endpoints` |
| Wrong `parentRefs.sectionName` | Route attaches to wrong listener | Match `sectionName` to the listener `name` in the Gateway |
