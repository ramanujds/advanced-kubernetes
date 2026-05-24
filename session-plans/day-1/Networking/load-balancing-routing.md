# Load Balancing and Traffic Routing in Kubernetes

## The Problem: Many Pods, One Service

A Deployment runs multiple replicas of `part-inventory-service`. A caller needs to reach any healthy replica — not a specific pod IP, which changes every restart.

```text
Client request
     │
     ▼
ClusterIP Service (10.96.45.12:80)   ← stable virtual IP
     │
     ├──► Pod 10.0.0.5:8080   (replica 1)
     ├──► Pod 10.0.0.6:8080   (replica 2)
     └──► Pod 10.0.0.7:8080   (replica 3)
```

Kubernetes load balancing works at multiple layers, each with different trade-offs.

---

## Layer 1 — kube-proxy: ClusterIP Load Balancing

Every node runs `kube-proxy`. It watches the API server for Service and Endpoint changes and programs **iptables** (or IPVS) rules to implement the virtual IP.

### How iptables Rules Work

When a pod sends a request to `10.96.45.12:80` (ClusterIP), iptables DNAT rules intercept it and rewrite the destination to one of the backing pods — chosen with random probability matching the weight.

```bash
# See the iptables chains kube-proxy created
sudo iptables -t nat -L KUBE-SERVICES | grep part-inventory
# KUBE-SVC-XXXX   tcp  --  anywhere  10.96.45.12  tcp dpt:80

sudo iptables -t nat -L KUBE-SVC-XXXX
# KUBE-SEP-AAA    0 -- anywhere  anywhere  statistic mode random probability 0.33
# KUBE-SEP-BBB    0 -- anywhere  anywhere  statistic mode random probability 0.50
# KUBE-SEP-CCC    0 -- anywhere  anywhere
# Each KUBE-SEP-* chain DNATs to one pod IP
```

This is **client-side load balancing at the network layer** — no dedicated load balancer process handles the traffic; the kernel redirects it.

### IPVS Mode (Alternative to iptables)

For clusters with thousands of services, iptables becomes slow (linear scan). IPVS is hash-based and supports additional algorithms:

```bash
# Check if IPVS mode is active
kubectl get configmap kube-proxy -n kube-system -o yaml | grep mode
# mode: "ipvs"   # or "" for iptables

# With IPVS, inspect virtual servers
kubectl exec -n kube-system <kube-proxy-pod> -- ipvsadm -Ln | grep -A4 10.96.45.12
# TCP  10.96.45.12:80 rr
#   -> 10.0.0.5:8080   Round Robin   1
#   -> 10.0.0.6:8080   Round Robin   1
#   -> 10.0.0.7:8080   Round Robin   1
```

IPVS scheduling algorithms: `rr` (round-robin, default), `lc` (least connection), `sh` (source hash for session affinity).

---

## Layer 2 — Service Types and External Load Balancing

### ClusterIP (default)

Reachable only inside the cluster. Used for service-to-service communication.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: part-inventory-service
  namespace: inventory-service
spec:
  selector:
    app: part-inventory-service
  ports:
    - port: 80
      targetPort: 8080
  type: ClusterIP
```

### NodePort

Opens a static port on every node. Requests to `<NodeIP>:30082` are forwarded to the pods.

```yaml
spec:
  type: NodePort
  ports:
    - port: 80
      targetPort: 8080
      nodePort: 30082      # static port 30000-32767 range
```

```bash
# Access from outside the cluster (minikube)
curl http://$(minikube ip --profile=advanced-k8s):30082/api/part-orders
```

NodePort routes through the same iptables DNAT rules — any node can serve the request regardless of which node the pod runs on.

### LoadBalancer

Provisions a cloud load balancer (GCE, AWS NLB/ALB, etc.) with a public IP. The LB forwards to the NodePort, which forwards to pods.

```yaml
spec:
  type: LoadBalancer
  ports:
    - port: 80
      targetPort: 8080
```

```bash
# Check the external IP (takes 1-3 minutes on GKE)
kubectl get svc part-inventory-service -n inventory-service
# NAME                     TYPE           CLUSTER-IP    EXTERNAL-IP      PORT(S)
# part-inventory-service   LoadBalancer   10.96.45.12   34.90.xxx.xxx    80:31234/TCP
```

**Cost note**: Each `LoadBalancer` service creates a separate cloud load balancer. At scale (20+ services), this is expensive — Ingress or Gateway API is the standard solution.

### ExternalName

A DNS alias that maps a Service to an external hostname. No proxying — kube-proxy programs a CNAME record in CoreDNS.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: external-db
  namespace: inventory-service
spec:
  type: ExternalName
  externalName: db.prod.company.com
```

Pods that connect to `external-db.inventory-service` resolve to `db.prod.company.com`.

---

## Layer 3 — Session Affinity

By default, each request goes to a random pod. For stateful protocols (WebSockets, server-side sessions), pin a client to the same pod:

```yaml
spec:
  selector:
    app: part-inventory-service
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 3600    # sticky for 1 hour
```

kube-proxy uses the client IP to select the same backend pod consistently. Note: this breaks even load distribution when many requests come from a NAT gateway (same source IP).

---

## Layer 4 — Endpoint Management: How kube-proxy Knows What's Healthy

### Endpoints

A `Service` points to an `Endpoints` object (auto-managed) listing the pod IPs currently passing readiness checks.

```bash
# See which pods are in the load balancer pool
kubectl get endpoints part-inventory-service -n inventory-service
# NAME                     ENDPOINTS                                     AGE
# part-inventory-service   10.0.0.5:8080,10.0.0.6:8080,10.0.0.7:8080   5d

# Describe shows addresses (ready) and notReadyAddresses (failing readiness)
kubectl describe endpoints part-inventory-service -n inventory-service
```

When a pod's readiness probe fails, it is removed from `Endpoints` and kube-proxy stops routing traffic to it — zero-downtime during rolling updates.

### Readiness Probes: The Gate to the Load Balancer

```yaml
spec:
  containers:
    - name: part-inventory-service
      readinessProbe:
        httpGet:
          path: /actuator/health/readiness
          port: 8080
        initialDelaySeconds: 10
        periodSeconds: 5
        failureThreshold: 3
```

A pod is added to the Endpoints (and therefore receives traffic) **only after** the readiness probe succeeds. It is removed as soon as the probe fails three consecutive times.

```bash
# Watch endpoints update during a rolling restart
kubectl rollout restart deployment/part-inventory-service -n inventory-service
kubectl get endpoints part-inventory-service -n inventory-service -w
# 10.0.0.5,10.0.0.6,10.0.0.7  ← before
# 10.0.0.5,10.0.0.6            ← old pod removed, new pod not ready yet
# 10.0.0.5,10.0.0.6,10.0.0.8  ← new pod passed readiness, added back
```

### EndpointSlices (>= Kubernetes 1.21)

For large services (1000+ pods), the `Endpoints` object in a single resource becomes slow to update. `EndpointSlice` shards it into groups of 100.

```bash
kubectl get endpointslices -n inventory-service
# NAME                              ADDRESSTYPE   PORTS   ENDPOINTS
# part-inventory-service-abc12      IPv4          8080    10.0.0.5,10.0.0.6,10.0.0.7
```

kube-proxy uses EndpointSlices by default since 1.21. Operators rarely interact with them directly.

---

## Layer 5 — Traffic Routing Decisions: kube-proxy vs Service Mesh

| Capability | kube-proxy | Ingress/Gateway API | Service Mesh (Istio) |
| ---------- | ---------- | ------------------- | -------------------- |
| Round-robin to pods | Yes | Yes (via Service) | Yes |
| Weighted traffic split (canary) | No | Yes (Gateway API) | Yes (VirtualService) |
| Header-based routing | No | Yes | Yes |
| Health-aware (readiness) | Yes (Endpoints) | Yes | Yes |
| Retries on failure | No | Limited | Yes |
| Circuit breaking | No | No | Yes |
| mTLS | No | No | Yes |
| Per-request observability | No | Partial | Yes |

Use kube-proxy (Services) for uniform distribution. Layer in Gateway API or Istio when you need intelligent routing.

---

## Lab — Observe Load Balancing in Action

### Step 1 — Verify the endpoints pool

```bash
kubectl get endpoints part-inventory-service -n inventory-service
```

### Step 2 — Run repeated requests, note pod names

```bash
kubectl port-forward svc/part-order-service 8082:80 -n order-service &

for i in $(seq 1 10); do
  curl -s http://localhost:8082/api/part-orders/available-parts | jq -r '.podName // "no podName field"'
done
```

If `part-inventory-service` includes the pod name in its response, you will see the requests distributed across replicas.

### Step 3 — Scale up and watch the pool grow

```bash
kubectl scale deployment part-inventory-service --replicas=4 -n inventory-service

# Endpoints should now list 4 IPs
kubectl get endpoints part-inventory-service -n inventory-service
```

### Step 4 — Fail a pod and confirm it leaves the pool

```bash
# Find a pod and exec a command that breaks its readiness
POD=$(kubectl get pods -n inventory-service -l app=part-inventory-service -o name | head -1)

# Simulate readiness failure: kill the actuator endpoint (or temporarily scale to 0 replicas)
kubectl patch deployment part-inventory-service -n inventory-service \
  --patch '{"spec":{"template":{"spec":{"containers":[{"name":"part-inventory-service","readinessProbe":{"httpGet":{"path":"/does-not-exist"}}}]}}}}'

# Watch the pod drop from 2/2 to 2/2 → 1/2 and disappear from endpoints
kubectl get endpoints part-inventory-service -n inventory-service -w

# Restore
kubectl rollout undo deployment/part-inventory-service -n inventory-service
```

---

## Advanced: Traffic Distribution Policy (Kubernetes 1.30+)

The `trafficDistribution` field on a Service hints to kube-proxy to prefer pods on the same node — useful for latency-sensitive services.

```yaml
spec:
  selector:
    app: part-inventory-service
  trafficDistribution: PreferClose   # prefer same-zone / same-node endpoints
```

For clusters spanning multiple zones, this reduces cross-zone network costs and latency without requiring a full topology-aware routing setup.

```bash
# Older equivalent — topology keys (deprecated in 1.27, removed in 1.30)
# spec.topologyKeys: ["kubernetes.io/hostname", "*"]
# Replaced by trafficDistribution
```

---

## Common Issues

| Issue | Symptom | Fix |
| ----- | ------- | --- |
| Pod not receiving traffic | Pod is `Running` but `1/1` | Readiness probe failing — `kubectl describe pod` shows probe failure |
| Traffic not balanced evenly | All requests hit one pod | `sessionAffinity: ClientIP` is set; check if intentional |
| Service IP unreachable | `curl ClusterIP` times out | kube-proxy pod not running or iptables rules not programmed |
| New pod never receives traffic | Pod stuck in `0/2 Ready` | Readiness probe path wrong, or `initialDelaySeconds` too short |
| Cross-zone latency spikes | Requests sometimes slow | Pods spread across zones; add `trafficDistribution: PreferClose` |
