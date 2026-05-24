# Istio — Setup and Implementation

## Istio Architecture

```text
┌─────────────────────────────────────────────────┐
│  Istiod (Control Plane)                          │
│  ┌──────────┐  ┌──────────┐  ┌───────────────┐  │
│  │  Pilot   │  │  Citadel │  │    Galley     │  │
│  │ (routes) │  │  (certs) │  │  (validation) │  │
│  └──────────┘  └──────────┘  └───────────────┘  │
└────────────────────┬────────────────────────────┘
                     │ xDS API (pushes config to proxies)
        ┌────────────┼─────────────┐
        ▼            ▼             ▼
  order-service  inventory-svc   mysql
  [app+envoy]    [app+envoy]   [app+envoy]
```

**Istiod** is a single binary since Istio 1.5 that merges Pilot (traffic management), Citadel (certificate authority), and Galley (config validation).

**Envoy** sidecars are injected automatically into pods in labeled namespaces. They intercept all inbound/outbound traffic via iptables init-container rules.

---

## Install Istio on advanced-k8s

### Step 1 — Download istioctl

```bash
# Download and install the istioctl CLI
curl -L https://istio.io/downloadIstio | ISTIO_VERSION=1.22.0 sh -

# Add to PATH
export PATH=$PWD/istio-1.22.0/bin:$PATH

# Verify
istioctl version
```

### Step 2 — Install Istio with the demo profile

The `demo` profile enables all features and is suitable for learning. Production uses `default` or a custom profile.

```bash
# Pre-check: verify cluster meets requirements
istioctl x precheck

# Install with demo profile (includes Kiali, Jaeger, Prometheus, Grafana)
istioctl install --set profile=demo -y

# Verify Istio control plane is running
kubectl get pods -n istio-system
# NAME                                    READY   STATUS
# istiod-xxxx                             1/1     Running
# istio-ingressgateway-xxxx               1/1     Running
# istio-egressgateway-xxxx                1/1     Running
```

### Step 3 — Install observability addons

```bash
kubectl apply -f istio-1.22.0/samples/addons/prometheus.yaml
kubectl apply -f istio-1.22.0/samples/addons/grafana.yaml
kubectl apply -f istio-1.22.0/samples/addons/jaeger.yaml
kubectl apply -f istio-1.22.0/samples/addons/kiali.yaml

kubectl rollout status deployment/kiali -n istio-system
```

### Step 4 — Enable sidecar injection

Label the namespaces to enable automatic Envoy sidecar injection:

```bash
kubectl label namespace inventory-service istio-injection=enabled
kubectl label namespace order-service istio-injection=enabled

# Verify labels
kubectl get namespace -L istio-injection
```

### Step 5 — Redeploy services to get sidecars injected

```bash
# Restart deployments so Istio injects the Envoy sidecar
kubectl rollout restart deployment/part-inventory-service -n inventory-service
kubectl rollout restart deployment/part-order-service -n order-service

# Verify — each pod should now have 2 containers (app + istio-proxy)
kubectl get pods -n inventory-service
# NAME                                    READY   STATUS
# part-inventory-service-xxxx             2/2     Running
#                                         ↑
#                                  2 = app + envoy sidecar

# Confirm the sidecar
kubectl describe pod <pod-name> -n inventory-service | grep -A2 "istio-proxy"
```

---

## Verify the Mesh is Working

```bash
# Check proxy status — are all proxies in sync with Istiod?
istioctl proxy-status

# NAME                                     CLUSTER  CDS    LDS    EDS    RDS
# part-inventory-service-xxxx.inventory    default  SYNCED SYNCED SYNCED SYNCED
# part-order-service-xxxx.order-service    default  SYNCED SYNCED SYNCED SYNCED

# Analyze config for issues
istioctl analyze -n inventory-service
```

Send a test request and confirm the mesh is handling it:

```bash
kubectl port-forward svc/part-order-service 8082:80 -n order-service &

curl -s http://localhost:8082/api/part-orders/available-parts | jq .

# Check that Istio emitted metrics for this call
kubectl exec -it deploy/part-order-service -n order-service \
  -c istio-proxy -- curl -s localhost:15000/stats | grep inventory
```

---

## Example 1 — mTLS: Encrypt All Traffic

By default in `STRICT` mode, all service-to-service traffic uses mTLS automatically. Verify it:

```bash
# Check mTLS mode for the namespace
kubectl get peerauthentication -A

# If none exists, traffic is in PERMISSIVE mode (accepts both plain and mTLS)
# Set STRICT to reject all plain HTTP between services
```

```yaml
apiVersion: security.istio.io/v1beta1
kind: PeerAuthentication
metadata:
  name: default
  namespace: inventory-service
spec:
  mtls:
    mode: STRICT
```

```bash
kubectl apply -f kubernetes-manifests/peer-auth-strict.yaml

# Verify mTLS is active — look for mTLS indicators in Kiali graph
istioctl authn tls-check <inventory-pod> part-inventory-service.inventory-service.svc.cluster.local
# HOST                                              STATUS       SERVER      CLIENT
# part-inventory-service.inventory-service...       OK           mTLS        mTLS
```

---

## Example 2 — Traffic Management: Canary Release

Deploy v2 of the inventory service alongside v1 and split traffic.

### Step 1 — Deploy v2

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: part-inventory-service-v2
  namespace: inventory-service
spec:
  replicas: 1
  selector:
    matchLabels:
      app: part-inventory-service
      version: v2
  template:
    metadata:
      labels:
        app: part-inventory-service
        version: v2
    spec:
      containers:
        - name: part-inventory-service
          image: ram1uj/part-inventory-service:v2
          ports:
            - containerPort: 8080
```

### Step 2 — DestinationRule: Define subsets

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: inventory-destination
  namespace: inventory-service
spec:
  host: part-inventory-service
  subsets:
    - name: v1
      labels:
        version: v1
    - name: v2
      labels:
        version: v2
```

### Step 3 — VirtualService: Split traffic 90/10

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: inventory-canary
  namespace: inventory-service
spec:
  hosts:
    - part-inventory-service
  http:
    - route:
        - destination:
            host: part-inventory-service
            subset: v1
          weight: 90
        - destination:
            host: part-inventory-service
            subset: v2
          weight: 10
```

```bash
kubectl apply -f kubernetes-manifests/destination-rule.yaml
kubectl apply -f kubernetes-manifests/virtual-service-canary.yaml

# Observe the split in real time
for i in $(seq 1 20); do
  curl -s http://localhost:8082/api/part-orders/available-parts | jq .version
done
# ~18 responses "v1", ~2 responses "v2"
```

---

## Example 3 — Header-Based Routing (A/B Testing)

Route requests with `X-Beta: true` header to v2, everyone else to v1:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: inventory-ab
  namespace: inventory-service
spec:
  hosts:
    - part-inventory-service
  http:
    - match:
        - headers:
            x-beta:
              exact: "true"
      route:
        - destination:
            host: part-inventory-service
            subset: v2
    - route:
        - destination:
            host: part-inventory-service
            subset: v1
```

```bash
# Regular request → v1
curl http://localhost:8082/api/part-orders/available-parts

# Beta header → v2
curl -H "x-beta: true" http://localhost:8082/api/part-orders/available-parts
```

---

## Example 4 — Fault Injection (Chaos Testing)

Inject failures to test your service's resilience without touching code:

### Inject 5-second delay for 50% of requests

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: inventory-fault-delay
  namespace: inventory-service
spec:
  hosts:
    - part-inventory-service
  http:
    - fault:
        delay:
          percentage:
            value: 50
          fixedDelay: 5s
      route:
        - destination:
            host: part-inventory-service
            subset: v1
```

```bash
kubectl apply -f kubernetes-manifests/virtual-service-fault-delay.yaml

# Test — about half the calls will take 5+ seconds
time curl http://localhost:8082/api/part-orders/available-parts
```

### Inject HTTP 503 for 20% of requests

```yaml
spec:
  http:
    - fault:
        abort:
          percentage:
            value: 20
          httpStatus: 503
      route:
        - destination:
            host: part-inventory-service
            subset: v1
```

---

## Example 5 — Retries and Timeouts

Configure retry behaviour and timeouts in the mesh — no code change in the order service:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: VirtualService
metadata:
  name: inventory-resilience
  namespace: inventory-service
spec:
  hosts:
    - part-inventory-service
  http:
    - timeout: 3s                        # total timeout for the request
      retries:
        attempts: 3                      # retry up to 3 times
        perTryTimeout: 1s                # each attempt gets 1 second
        retryOn: "5xx,reset,connect-failure,retriable-4xx"
      route:
        - destination:
            host: part-inventory-service
            subset: v1
```

```bash
kubectl apply -f kubernetes-manifests/virtual-service-resilience.yaml

# With fault injection active: Istio retries the 503 automatically
# Order service sees a clean response after the retry
```

---

## Example 6 — Circuit Breaker

Stop sending traffic to an overloaded instance using `DestinationRule` outlier detection:

```yaml
apiVersion: networking.istio.io/v1beta1
kind: DestinationRule
metadata:
  name: inventory-circuit-breaker
  namespace: inventory-service
spec:
  host: part-inventory-service
  trafficPolicy:
    connectionPool:
      tcp:
        maxConnections: 10
      http:
        http1MaxPendingRequests: 5
        maxRequestsPerConnection: 2
    outlierDetection:
      consecutive5xxErrors: 3          # eject after 3 consecutive 5xx
      interval: 10s                    # check every 10 seconds
      baseEjectionTime: 30s            # keep ejected for at least 30 seconds
      maxEjectionPercent: 50           # eject at most 50% of endpoints
```

```bash
kubectl apply -f kubernetes-manifests/destination-rule-cb.yaml

# Simulate overload — inject 503s, watch the circuit open
# After 3 consecutive 5xx from one endpoint, Istio stops sending it traffic for 30s
```

---

## Example 7 — Authorization Policy

Enforce that only `part-order-service` can call `part-inventory-service`. All other callers are denied.

### Step 1 — Deny all traffic by default

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: deny-all
  namespace: inventory-service
spec:
  {}   # empty spec = deny everything
```

### Step 2 — Allow only order-service

```yaml
apiVersion: security.istio.io/v1beta1
kind: AuthorizationPolicy
metadata:
  name: allow-order-service
  namespace: inventory-service
spec:
  selector:
    matchLabels:
      app: part-inventory-service
  action: ALLOW
  rules:
    - from:
        - source:
            principals:
              - "cluster.local/ns/order-service/sa/default"
      to:
        - operation:
            methods: ["GET", "POST"]
            paths: ["/api/parts*"]
```

The principal is the SPIFFE identity of the order-service pod: `cluster.local/ns/<namespace>/sa/<service-account>`.

```bash
kubectl apply -f kubernetes-manifests/authz-deny-all.yaml
kubectl apply -f kubernetes-manifests/authz-allow-order.yaml

# Order service call → allowed
curl http://localhost:8082/api/part-orders/available-parts

# Direct call from outside the mesh → denied
kubectl run curl --image=curlimages/curl --rm -it --restart=Never \
  -- curl http://part-inventory-service.inventory-service:80/api/parts
# RBAC: access denied
```

---

## Observability: Kiali, Grafana, Jaeger

### Open the dashboards

```bash
# Kiali — service graph, traffic flow, health
istioctl dashboard kiali

# Grafana — Istio built-in dashboards (service workload, mesh overview)
istioctl dashboard grafana

# Jaeger — distributed tracing (follow a request across services)
istioctl dashboard jaeger
```

### Generate traffic to see the graphs

```bash
# Run 100 requests in the background to populate the dashboards
for i in $(seq 1 100); do
  curl -s http://localhost:8082/api/part-orders/available-parts > /dev/null
  sleep 0.1
done &
```

**Kiali service graph** shows:

- Live traffic flow between order-service and inventory-service
- mTLS lock icon on each edge
- Error rate per service (red edges when >1% errors)
- Response time per edge

**Jaeger traces** show the full request path from order-service → inventory-service with per-hop latency.

---

## Cleanup: Remove Istio

```bash
# Remove applied manifests
kubectl delete -f kubernetes-manifests/

# Uninstall Istio control plane
istioctl uninstall --purge -y

# Remove namespace labels
kubectl label namespace inventory-service istio-injection-
kubectl label namespace order-service istio-injection-

# Delete the istio-system namespace
kubectl delete namespace istio-system
```

---

## Verification Commands

```bash
# Proxy sync status across the mesh
istioctl proxy-status

# Config dump for a specific pod (full Envoy config)
istioctl proxy-config all <pod-name> -n inventory-service

# View listener config (what ports Envoy is listening on)
istioctl proxy-config listeners <pod-name> -n inventory-service

# View route config (what routing rules are applied)
istioctl proxy-config routes <pod-name> -n inventory-service

# View cluster config (what backends Envoy knows about)
istioctl proxy-config clusters <pod-name> -n inventory-service

# Check for config issues across the mesh
istioctl analyze -A

# Verify mTLS handshake for a specific service
istioctl authn tls-check <pod-name> part-inventory-service.inventory-service.svc.cluster.local
```

---

## Common Issues

| Issue | Symptom | Fix |
| ----- | ------- | --- |
| Pod shows `1/1` not `2/2` | Sidecar not injected | Verify namespace has `istio-injection=enabled` label; restart deployment |
| 503 with `upstream connect error` | Envoy can't reach backend | Check `istioctl proxy-status` — proxy may be out of sync |
| AuthorizationPolicy blocks all traffic | All requests return `RBAC: access denied` | Apply deny-all only after allow rules are in place; check principal name |
| VirtualService not applied | Traffic ignores the routing rules | `istioctl analyze` — missing DestinationRule subsets or wrong host name |
| Tracing headers not propagated | Jaeger shows broken traces | App must forward `x-b3-*` and `x-request-id` headers — Feign propagates them if configured |
| mTLS STRICT breaks health checks | kubelet liveness probes fail | Annotate the port: `traffic.sidecar.istio.io/excludeInboundPorts: "15021"` |
