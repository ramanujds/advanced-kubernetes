# Module 2: Networking in Kubernetes
## Day 1 | 1:30 PM – 3:00 PM

---

### Lecture Notes (40 min)

#### The Kubernetes Networking Model (3 Rules)

1. **Every pod gets a unique IP** — no NAT between pods
2. **All pods can communicate with all other pods** — flat L3 network
3. **Agents on a node can communicate with all pods** on that node

```
Node A                          Node B
┌──────────────────┐            ┌──────────────────┐
│  Pod 10.244.1.2  │──────────▶│  Pod 10.244.2.5  │
│  Pod 10.244.1.3  │            │  Pod 10.244.2.6  │
└──────────────────┘            └──────────────────┘
          CNI plugin handles cross-node routing
```

#### IP Allocation

```
Cluster CIDR:   10.244.0.0/16  (pod IPs — assigned by CNI)
Service CIDR:   10.96.0.0/12   (virtual IPs — assigned by kube-apiserver)
Node CIDR:      each node gets a /24 slice (e.g. 10.244.1.0/24)
```

Check your cluster's CIDRs:
```bash
kubectl cluster-info dump | grep -m 2 -E "cluster-cidr|service-cluster-ip-range"
```

#### CNI Plugins Comparison

| Plugin | Network Policy | IPAM | Performance | Use Case |
|---|---|---|---|---|
| **Flannel** | No (needs plugin) | Simple | Good | Dev/simple setups |
| **Calico** | Yes (native) | Flexible | Excellent | Production, network policies |
| **Weave** | Yes | Built-in | Good | Encrypted mesh |
| **Cilium** | Yes (eBPF) | Advanced | Best | High-perf, observability |

**minikube default:** Kindnet (simple, no network policies). Use `--cni=calico` for network policy support.

---

#### Kubernetes Services

**Why Services exist:** Pod IPs are ephemeral — pods restart with new IPs. Services provide a stable virtual IP (ClusterIP) that persists.

```
Client → Service VIP (ClusterIP) → kube-proxy → Pod IPs (round-robin)
```

#### Service Types

```yaml
ClusterIP (default):
  - Internal VIP only
  - Reachable only within the cluster
  - Use for: inter-service communication

NodePort:
  - Exposes on every node's IP at a static port (30000-32767)
  - Reachable from outside the cluster: <NodeIP>:<NodePort>
  - Use for: dev/testing external access

LoadBalancer:
  - Provisions cloud provider LB (AWS NLB, GCP LB, etc.)
  - Gets external IP automatically
  - Use for: production external traffic

ExternalName:
  - DNS alias to external service (e.g. database.example.com)
  - Use for: external dependency abstraction
```

#### Service DNS — CoreDNS

Every Service gets a DNS record automatically:

```
Format: <service-name>.<namespace>.svc.cluster.local

Examples:
  part-inventory-service.inventory-service.svc.cluster.local
  part-order-service.order-service.svc.cluster.local

Short form (within same namespace):
  part-inventory-service

Cross-namespace short form:
  part-inventory-service.inventory-service
```

How DNS resolution works:
```
Pod → /etc/resolv.conf → nameserver 10.96.0.10 (CoreDNS ClusterIP)
CoreDNS → looks up Service in etcd via kube-apiserver → returns ClusterIP
```

Check a pod's DNS config:
```bash
kubectl exec -it <pod-name> -- cat /etc/resolv.conf
```

#### How kube-proxy Routes Traffic

```
Service ClusterIP 10.96.45.12:8080
          │
          ▼
     iptables/IPVS rules on each node
          │
     ┌────┴─────────────────┐
     │                      │
  Pod 10.244.1.2:8080    Pod 10.244.2.3:8080
  Pod 10.244.3.5:8080
```

Default algorithm: **random** (not strict round-robin). For session affinity:
```yaml
spec:
  sessionAffinity: ClientIP
  sessionAffinityConfig:
    clientIP:
      timeoutSeconds: 10800
```

#### Endpoints — The Link Between Service and Pods

Kubernetes automatically creates an `Endpoints` object for every Service. When pods match the selector, they're added to Endpoints:

```bash
kubectl get endpoints part-inventory-service -n inventory-service
```

If Endpoints is empty → pods don't match the Service selector (label mismatch).

---

### Lab 1.3 — Deploy Services with Advanced Networking (50 min)

**Goal:** Deploy both microservices across namespaces, verify DNS resolution and load balancing.

#### Phase 1 — Deploy Services (20 min)

```bash
# Deploy inventory service (3 replicas) in its namespace
kubectl apply -f kuberneters-manifests/part-inventory-deployment.yaml
kubectl apply -f kuberneters-manifests/part-inventory-service.yaml

# Deploy order service (3 replicas) in its namespace
kubectl apply -f kuberneters-manifests/part-order-deployment.yaml
kubectl apply -f kuberneters-manifests/part-order-service.yaml

# Watch rollout
kubectl rollout status deployment/part-inventory-service -n inventory-service
kubectl rollout status deployment/part-order-service -n order-service

# Verify all pods are running
kubectl get pods -n inventory-service -o wide
kubectl get pods -n order-service -o wide
```

#### Phase 2 — Service Discovery & DNS Testing (20 min)

**Test DNS from within the cluster:**

```bash
# Launch a debug pod in order-service namespace
kubectl run dns-test --image=busybox:1.36 -n order-service --restart=Never \
  --command -- sleep 3600

# Test DNS resolution (within same namespace)
kubectl exec -n order-service dns-test -- nslookup part-order-service

# Test cross-namespace DNS (short form with namespace)
kubectl exec -n order-service dns-test -- nslookup part-inventory-service.inventory-service

# Test FQDN
kubectl exec -n order-service dns-test -- nslookup \
  part-inventory-service.inventory-service.svc.cluster.local

# Test HTTP connectivity
kubectl exec -n order-service dns-test -- wget -qO- \
  http://part-inventory-service.inventory-service.svc.cluster.local:8080/api/parts

# Cleanup
kubectl delete pod dns-test -n order-service
```

**Verify Endpoints are populated:**
```bash
kubectl get endpoints -n inventory-service
kubectl get endpoints -n order-service

# Should show 3 pod IPs for each service
kubectl describe endpoints part-inventory-service -n inventory-service
```

**Test that part-order-service can reach inventory:**
```bash
# Get order service pod
ORDER_POD=$(kubectl get pod -n order-service -l app=part-order-service -o jsonpath='{.items[0].metadata.name}')

# Hit the proxy endpoint (order → inventory)
kubectl exec -n order-service $ORDER_POD -- \
  wget -qO- http://localhost:8080/api/part-orders/available-parts
```

#### Phase 3 — Load Balancing Verification (10 min)

```bash
# Watch which pod handles requests — check pod names in logs
kubectl logs -n inventory-service -l app=part-inventory-service -f &

# Send repeated requests
for i in $(seq 1 10); do
  kubectl exec -n order-service dns-test -- \
    wget -qO- http://part-inventory-service.inventory-service:8080/api/parts 2>/dev/null
  sleep 0.5
done

# Check which pods received requests
kubectl logs -n inventory-service -l app=part-inventory-service --tail=5

# See endpoints and IPs that back the service
kubectl get endpoints part-inventory-service -n inventory-service -o yaml
```

**Simulate pod failure and recovery:**
```bash
# Delete one inventory pod — should auto-recover
kubectl delete pod -n inventory-service \
  $(kubectl get pod -n inventory-service -l app=part-inventory-service -o jsonpath='{.items[0].metadata.name}')

# Watch it recover immediately
kubectl get pods -n inventory-service -w

# Endpoints auto-update to remove the failing pod and add the new one
kubectl get endpoints part-inventory-service -n inventory-service
```

**Access from outside (NodePort):**
```bash
# Get the minikube IP
minikube ip -p advanced-k8s

# part-order-service is on NodePort 30082
curl http://$(minikube ip -p advanced-k8s):30082/api/part-orders

# part-inventory-service is on NodePort 30081
curl http://$(minikube ip -p advanced-k8s):30081/api/parts
```

---

## Key Commands Reference

```bash
# Service and endpoint inspection
kubectl get svc -A
kubectl get endpoints -n <namespace>
kubectl describe svc <service-name> -n <namespace>

# DNS debugging
kubectl run dns-debug --image=busybox:1.36 --restart=Never -- sleep 3600
kubectl exec dns-debug -- nslookup <service>.<namespace>
kubectl exec dns-debug -- cat /etc/resolv.conf

# Pod connectivity
kubectl exec -it <pod> -n <ns> -- wget -qO- http://<service>:<port>/health

# kube-proxy mode
kubectl get configmap kube-proxy -n kube-system -o yaml | grep mode

# CoreDNS config
kubectl get configmap coredns -n kube-system -o yaml

# Service CIDR
kubectl cluster-info dump | grep service-cluster-ip-range
```

---

## Architecture: Order/Inventory Service Communication

```
External User
     │
     ▼ (NodePort 30082)
part-order-service (ClusterIP 10.96.x.x:8080)
  order-service namespace
     │
     │ FQDN DNS lookup:
     │ part-inventory-service.inventory-service.svc.cluster.local:8080
     │
     ▼ (ClusterIP 10.96.y.y:8080)
part-inventory-service
  inventory-service namespace
  [Pod 1] [Pod 2] [Pod 3]  ← kube-proxy distributes across replicas
```

**INVENTORY_SERVICE_URL in part-order-service deployment:**
```
http://part-inventory-service.inventory-service.svc.cluster.local:8080
```
This is set as an environment variable so no code changes are needed.

---

## Troubleshooting Quick Reference

| Symptom | Check | Fix |
|---|---|---|
| `nslookup` fails for service | `kubectl get pods -n kube-system` (CoreDNS) | Restart CoreDNS pods |
| Empty Endpoints | `kubectl describe svc` → selector labels | Verify pod labels match `spec.selector` |
| Connection refused | `kubectl get pods` (is pod Running?) | Check pod logs, liveness probe |
| Cross-namespace DNS fails | Using short name instead of FQDN | Use `svc.namespace` or full FQDN |
| NodePort unreachable | `minikube ip`, firewall rules | Check minikube tunnel or port-forward |
| Uneven load | Session affinity enabled? | Check `kubectl describe svc` for `sessionAffinity` |
