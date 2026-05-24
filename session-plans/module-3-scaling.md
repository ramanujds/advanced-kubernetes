# Module 3: Scaling Kubernetes Applications
## Day 1 | 3:15 PM – 4:45 PM

---

### Lecture Notes (40 min)

#### Kubernetes Autoscaling Levels

```
Level 1 — Pod level:
  HPA (Horizontal Pod Autoscaler) — adds/removes pod replicas
  VPA (Vertical Pod Autoscaler)   — adjusts CPU/memory requests per pod

Level 2 — Node level:
  Cluster Autoscaler              — adds/removes nodes (cloud provider)
  Karpenter                       — faster, more flexible node provisioning (AWS)

Today's focus: HPA (most commonly used in production)
```

#### Resource Requests and Why They Matter for HPA

HPA calculates utilization as:
```
Utilization % = (current CPU usage) / (CPU request) × 100
```

**If requests are not set → HPA cannot calculate utilization → HPA shows `<unknown>`.**

```yaml
resources:
  requests:
    cpu: "250m"       # Scheduler reserves this on the node
    memory: "256Mi"   # Scheduler reserves this on the node
  limits:
    cpu: "500m"       # Hard cap — CPU throttled at this
    memory: "512Mi"   # Hard cap — OOM killed if exceeded
```

Units:
- `1000m` = 1 CPU core | `500m` = 0.5 CPU core | `250m` = 0.25 CPU core
- `Mi` = mebibytes (1024²) | `Gi` = gibibytes

#### HPA — How It Works

```
metrics-server (collects CPU/mem from kubelet)
       │
       ▼
HPA controller (runs every 15s)
       │
       │ formula: desiredReplicas = ceil(currentReplicas × (currentMetric / targetMetric))
       │
       ▼
Deployment (scale up or down)
```

Example calculation:
```
currentReplicas = 3
currentCPU      = 85% average across pods
targetCPU       = 70%
desiredReplicas = ceil(3 × (85/70)) = ceil(3.64) = 4
```

**Scale-up:** Immediate (default: 15s evaluation period)
**Scale-down:** Delayed — 5-minute stabilization window to prevent thrashing

#### HPA Configuration

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: part-order-hpa
  namespace: order-service
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: part-order-service
  minReplicas: 3
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 70
  behavior:                          # optional: tune scale-down speed
    scaleDown:
      stabilizationWindowSeconds: 60
```

#### VPA — Overview (Informational)

```yaml
# VPA modes:
#   Off         → just recommendations, no action
#   Initial     → sets requests at pod creation only
#   Auto        → updates requests and restarts pods
#
# VPA and HPA conflict on CPU/memory — use HPA for CPU, VPA for memory
# Or: use HPA on custom metrics + VPA for resource right-sizing
```

#### Load Testing Tools

| Tool | Protocol | Best For |
|---|---|---|
| `hey` | HTTP | Simple HTTP benchmarking |
| `Apache Bench (ab)` | HTTP | Quick throughput test |
| `k6` | HTTP/gRPC | Scripted scenarios, CI integration |
| `wrk` | HTTP | High-connection-count testing |

For this lab we use `hey` — single binary, easy to install.

---

### Lab 1.4 — HPA & Load Testing (50 min)

**Goal:** Configure HPA for both services, generate load, observe autoscaling in action.

#### Phase 1 — Apply Resource Requests & HPA (15 min)

Deploy updated manifests (resource requests are already set):
```bash
# Deployments already have resource requests from Lab 1.3
# Apply HPA objects
kubectl apply -f kuberneters-manifests/hpa-inventory.yaml
kubectl apply -f kuberneters-manifests/hpa-order.yaml

# Verify HPA objects were created
kubectl get hpa -n inventory-service
kubectl get hpa -n order-service
```

Expected output (before load — targets may show `<unknown>` briefly):
```
NAME                   REFERENCE                         TARGETS   MINPODS   MAXPODS   REPLICAS
part-inventory-hpa     Deployment/part-inventory-service  5%/70%    3         8         3
part-order-hpa         Deployment/part-order-service       3%/70%    3         10        3
```

If TARGETS shows `<unknown>`:
```bash
# Check metrics-server is running
kubectl get pods -n kube-system | grep metrics-server

# Check metrics are flowing
kubectl top pods -n order-service
kubectl top pods -n inventory-service

# If metrics-server missing, enable it in minikube
minikube addons enable metrics-server -p advanced-k8s
```

#### Phase 2 — Metrics Baseline (10 min)

```bash
# Baseline resource usage before load
kubectl top pods -n order-service
kubectl top pods -n inventory-service
kubectl top nodes

# Watch HPA status live
kubectl get hpa -n order-service -w &
```

Record baseline CPU % — this is your reference point.

#### Phase 3 — Load Testing & Scaling Validation (20 min)

**Install `hey` for load testing:**
```bash
# macOS
brew install hey

# Linux
curl -Lo hey https://hey-release.s3.us-east-2.amazonaws.com/hey_linux_amd64
chmod +x hey && sudo mv hey /usr/local/bin/
```

**Get the service endpoint:**
```bash
MINIKUBE_IP=$(minikube ip -p advanced-k8s)
ORDER_URL="http://${MINIKUBE_IP}:30082/api/part-orders/available-parts"
echo "Testing: $ORDER_URL"
```

**Run sustained load test:**
```bash
# Terminal 1: Watch pod scaling
kubectl get pods -n order-service -w &
kubectl get hpa -n order-service -w &

# Terminal 2: Generate load
# -c 50 concurrent workers, -z 3m duration, -q 100 req/sec
hey -c 50 -z 3m -q 100 ${ORDER_URL}
```

**Observe in real-time:**
```bash
# Check CPU climbing
watch kubectl top pods -n order-service

# HPA decisions
kubectl describe hpa part-order-hpa -n order-service

# Events show scaling decisions
kubectl get events -n order-service --sort-by='.lastTimestamp' | tail -10
```

Expected scaling sequence:
```
t=0min:   3 pods, CPU ~10%
t=1min:   CPU crosses 70% → HPA triggers
t=2min:   6-8 pods, CPU drops back to ~40%
t=3min:   Load stops
t=8min:   Scale-down begins (5-min stabilization window)
t=10min:  Back to 3 pods
```

**Test inventory service scaling:**
```bash
INV_URL="http://${MINIKUBE_IP}:30081/api/parts"
hey -c 30 -z 2m ${INV_URL}

# Watch inventory HPA
kubectl get hpa -n inventory-service -w
```

#### Phase 4 — Analysis (5 min)

```bash
# Final HPA status after load test
kubectl describe hpa part-order-hpa -n order-service
kubectl describe hpa part-inventory-hpa -n inventory-service

# Review scaling events
kubectl get events -n order-service --sort-by='.lastTimestamp'
kubectl get events -n inventory-service --sort-by='.lastTimestamp'

# Pod resource summary
kubectl top pods -n order-service
kubectl top pods -n inventory-service
```

**Discussion questions:**
- At what replica count did CPU stabilize?
- How long did scale-down take? Why the delay?
- What would happen if `maxReplicas` was too low?
- How would you tune the `70%` target for this workload?

---

## HPA Scaling Behavior — Fine Tuning Reference

```yaml
behavior:
  scaleUp:
    stabilizationWindowSeconds: 0      # scale up immediately (default)
    policies:
      - type: Pods
        value: 4                        # add max 4 pods per period
        periodSeconds: 60
  scaleDown:
    stabilizationWindowSeconds: 300    # wait 5 min before scaling down (default)
    policies:
      - type: Percent
        value: 50                       # scale down max 50% per period
        periodSeconds: 60
```

---

## Key Commands Reference

```bash
# HPA management
kubectl get hpa -n <namespace>
kubectl describe hpa <name> -n <namespace>
kubectl delete hpa <name> -n <namespace>

# Resource metrics
kubectl top pods -n <namespace>
kubectl top nodes

# Metrics server
kubectl get deployment metrics-server -n kube-system
kubectl logs deployment/metrics-server -n kube-system

# Manual scaling (overrides HPA temporarily)
kubectl scale deployment <name> --replicas=5 -n <namespace>

# Load testing
hey -c <concurrency> -z <duration> -q <rps> <url>
hey -c 50 -z 3m http://<ip>:<port>/api/endpoint

# Watch multiple resources
watch "kubectl get pods,hpa -n order-service"
```

---

## Troubleshooting Quick Reference

| Symptom | Check | Fix |
|---|---|---|
| HPA shows `<unknown>` targets | `kubectl top pods` — does it work? | Enable metrics-server addon |
| HPA not scaling up | `kubectl describe hpa` → events | Check CPU requests are set on containers |
| Pods evicted under load | `kubectl describe pod` → OOM | Increase memory limits or requests |
| Scale-down too slow | `stabilizationWindowSeconds` | Reduce to 60s for testing |
| Scaling thrashing | CPU bouncing around target | Increase target % or add stabilization window |
| `hey` can't reach service | NodePort reachable? | `curl http://$(minikube ip):30082/actuator/health` |
| Max replicas hit, still degraded | Not enough nodes | Increase `--nodes` in minikube or raise maxReplicas |

---

## Summary: Day 1 Deliverables

By the end of Lab 1.4, participants have:

| Deliverable | Manifest | Status |
|---|---|---|
| 3-node cluster | minikube setup | Lab 1.1 |
| `inventory-service` namespace + quota | `00-namespaces.yaml`, `01-resource-quotas.yaml` | Lab 1.2 |
| `order-service` namespace + quota | `00-namespaces.yaml`, `01-resource-quotas.yaml` | Lab 1.2 |
| Service accounts | `02-service-accounts.yaml` | Lab 1.2 |
| Inventory deployment (3 replicas) | `part-inventory-deployment.yaml` | Lab 1.3 |
| Order deployment (3 replicas) | `part-order-deployment.yaml` | Lab 1.3 |
| Inter-service DNS working | `INVENTORY_SERVICE_URL` env var | Lab 1.3 |
| HPA for inventory (max 8) | `hpa-inventory.yaml` | Lab 1.4 |
| HPA for order (max 10) | `hpa-order.yaml` | Lab 1.4 |
| Load test validated | `hey` results | Lab 1.4 |
