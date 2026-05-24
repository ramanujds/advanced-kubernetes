# Horizontal Pod Autoscaling (HPA) and Vertical Pod Autoscaling (VPA)

## The Problem: Static Replicas Don't Match Real Traffic

A fixed replica count is a compromise: too few means overload, too many means waste.

```text
Fixed replicas = 3
                    ┌─ peak (10x load, 3 pods struggle)
                    │
  Load ─────────────┤
                    │
                    └─ off-peak (1x load, 3 pods idle, wasting CPU/RAM)

HPA (scales out)
  Load ──▲──────────▼──  replicas: 3 → 10 → 3

VPA (scales up)
  Same pods, but requests/limits adjusted:
  300m CPU → 1200m CPU when under sustained load
```

HPA adds/removes pod replicas. VPA adjusts resource requests on existing pods. They solve different dimensions of the same problem.

---

## Horizontal Pod Autoscaler (HPA)

### How It Works

The HPA controller runs every 15 seconds (default). It reads metrics from the **Metrics Server**, computes the desired replica count, and updates the Deployment's `replicas` field.

```text
┌────────────────────────────────────────────────────────┐
│  HPA Control Loop (every 15s)                           │
│                                                         │
│  1. Read current metric value (CPU utilization)         │
│  2. Compute: desiredReplicas =                          │
│       ceil(currentReplicas × currentValue / target)     │
│  3. Clamp to [minReplicas, maxReplicas]                 │
│  4. Set deployment.spec.replicas                        │
└────────────────────────────────────────────────────────┘
```

**Example**: target CPU = 50%, current CPU = 80%, current replicas = 3

```text
desiredReplicas = ceil(3 × 80 / 50) = ceil(4.8) = 5
```

### Prerequisite — Metrics Server

HPA requires the Metrics Server to be running. It collects resource usage from kubelet.

```bash
# Enable on minikube
minikube addons enable metrics-server --profile=advanced-k8s

# Verify
kubectl get pods -n kube-system | grep metrics-server
# metrics-server-xxxx   1/1   Running

# Test — should show CPU/memory for nodes and pods
kubectl top nodes
kubectl top pods -n inventory-service
```

---

## Example 1 — CPU-Based HPA

Scale `part-inventory-service` between 2 and 10 replicas, targeting 50% CPU utilization.

### Step 1 — Ensure resource requests are set on the Deployment

HPA CPU utilization is calculated as `currentCPU / requests.cpu`. Without requests, HPA cannot compute utilization.

```yaml
spec:
  containers:
    - name: part-inventory-service
      resources:
        requests:
          cpu: "250m"
          memory: "256Mi"
        limits:
          cpu: "500m"
          memory: "512Mi"
```

### Step 2 — Create the HPA

```yaml
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: part-inventory-hpa
  namespace: inventory-service
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: part-inventory-service
  minReplicas: 2
  maxReplicas: 10
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50    # target: 50% of requests.cpu
```

```bash
kubectl apply -f kubernetes-manifests/hpa-inventory.yaml

# Check HPA status
kubectl get hpa -n inventory-service
# NAME                   REFERENCE                             TARGETS   MINPODS  MAXPODS  REPLICAS
# part-inventory-hpa     Deployment/part-inventory-service     12%/50%   2        10       2

# Describe for detailed event history
kubectl describe hpa part-inventory-hpa -n inventory-service
```

### Step 3 — Generate load and observe scaling

```bash
# Run a load generator in the cluster
kubectl run load-gen --image=busybox --rm -it --restart=Never -- \
  /bin/sh -c "while true; do wget -q -O- http://part-inventory-service.inventory-service/api/parts; done"

# Watch HPA react in a separate terminal
kubectl get hpa part-inventory-hpa -n inventory-service -w
# TARGETS    REPLICAS
# 12%/50%    2
# 68%/50%    2         ← load increasing
# 95%/50%    4         ← scaled out
# 102%/50%   8         ← still climbing
# 54%/50%    8         ← stabilising
# 48%/50%    8         ← at target

# Stop the load generator (Ctrl-C)
# HPA will scale back in after the stabilization window (default 5 minutes)
```

---

## Example 2 — Memory-Based HPA

```yaml
metrics:
  - type: Resource
    resource:
      name: memory
      target:
        type: AverageValue
        averageValue: 200Mi    # absolute average memory per pod, not a percentage
```

Memory autoscaling is less common because memory pressure often indicates a leak — scaling out adds pods but doesn't free the leak. Use it for workloads where memory usage genuinely correlates with request load (e.g., in-memory caches).

---

## Example 3 — Multi-Metric HPA

Scale when **either** CPU exceeds 50% **or** memory exceeds 300Mi — HPA uses whichever demands the higher replica count:

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
  minReplicas: 2
  maxReplicas: 8
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: 50
    - type: Resource
      resource:
        name: memory
        target:
          type: AverageValue
          averageValue: 300Mi
  behavior:
    scaleUp:
      stabilizationWindowSeconds: 60    # wait 60s before scaling up again
      policies:
        - type: Percent
          value: 100                    # can double replicas per step
          periodSeconds: 60
    scaleDown:
      stabilizationWindowSeconds: 300   # wait 5 min before scaling down
      policies:
        - type: Pods
          value: 1                      # remove at most 1 pod per 60s
          periodSeconds: 60
```

The `behavior` block controls scale velocity — fast up, slow down to avoid thrashing.

---

## Example 4 — Custom Metrics HPA (Requests Per Second)

For application-level scaling, use a custom metric exposed by Prometheus and adapted by the Prometheus Adapter.

```yaml
metrics:
  - type: Pods
    pods:
      metric:
        name: http_requests_per_second    # metric from Prometheus
      target:
        type: AverageValue
        averageValue: "100"               # target: 100 RPS per pod
```

This requires the **Prometheus Adapter** to bridge Prometheus metrics into the Kubernetes Custom Metrics API. When `part-inventory-service` is handling 500 RPS across 2 pods (250 RPS each), HPA scales to 5 pods (500 / 100).

---

## HPA Scaling Behavior: Scale-Up vs Scale-Down Asymmetry

Scale-up is aggressive (fast response to load). Scale-down is conservative (avoid thrashing when load briefly drops).

| Direction | Default stabilization window | Default policy |
| --------- | ---------------------------- | -------------- |
| Scale up | 0 seconds | +100% or +4 pods per minute |
| Scale down | 300 seconds (5 min) | -100% per 15 min (slow) |

The 5-minute scale-down window means replicas stay elevated for 5 minutes after load drops. Adjust with the `behavior` block if your workload is highly variable.

---

## Vertical Pod Autoscaler (VPA)

### What VPA Does

VPA watches pod resource usage and adjusts `requests` and `limits` on the pod spec. It answers: **"Is this pod correctly sized?"**

```text
Initial deployment:
  part-inventory-service   requests: cpu=100m  memory=128Mi

After VPA analysis (1 week of data):
  VPA recommendation:      requests: cpu=320m  memory=256Mi
  (service was consistently using more than requested)
```

### Install VPA

VPA is not built into Kubernetes — install it separately:

```bash
# Clone VPA repo and install
git clone https://github.com/kubernetes/autoscaler.git
cd autoscaler/vertical-pod-autoscaler

./hack/vpa-up.sh

# Verify components
kubectl get pods -n kube-system | grep vpa
# vpa-admission-controller-xxxx   1/1   Running
# vpa-recommender-xxxx            1/1   Running
# vpa-updater-xxxx                1/1   Running
```

### VPA Components

| Component | Role |
| --------- | ---- |
| **Recommender** | Watches metrics history, computes recommended requests |
| **Updater** | Evicts pods so they restart with new requests (in `Auto` mode) |
| **Admission Controller** | Mutates pod specs at creation time with VPA recommendations |

---

## VPA Modes

```yaml
apiVersion: autoscaling.k8s.io/v1
kind: VerticalPodAutoscaler
metadata:
  name: part-inventory-vpa
  namespace: inventory-service
spec:
  targetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: part-inventory-service
  updatePolicy:
    updateMode: "Off"    # see table below
  resourcePolicy:
    containerPolicies:
      - containerName: part-inventory-service
        minAllowed:
          cpu: 100m
          memory: 128Mi
        maxAllowed:
          cpu: 2
          memory: 2Gi
```

| Mode | Behaviour | Use when |
| ---- | --------- | -------- |
| `Off` | Only recommendations, no changes | Learn correct sizing without disruption |
| `Initial` | Apply at pod creation only, no evictions | Correct new pods, leave running pods alone |
| `Auto` | Apply recommendations + evict pods to resize | Fully automated (causes restarts) |
| `Recreate` | Like Auto but only evicts, no in-place update | Same as Auto on older Kubernetes |

Start with `Off` to gather recommendations, then switch to `Initial` or `Auto` once validated.

---

## Reading VPA Recommendations

```bash
kubectl describe vpa part-inventory-vpa -n inventory-service
```

```text
Recommendation:
  Container Recommendations:
    Container Name:  part-inventory-service
    Lower Bound:
      Cpu:     100m
      Memory:  256Mi
    Target:
      Cpu:     320m        ← this is what VPA will set as requests
      Memory:  384Mi
    Uncapped Target:
      Cpu:     320m
      Memory:  384Mi
    Upper Bound:
      Cpu:     700m
      Memory:  768Mi
```

- **Target** — what VPA recommends setting as `requests`
- **Lower Bound** — minimum observed; requests below this risk OOMKill
- **Upper Bound** — safety ceiling; requests above this are wasteful

---

## HPA + VPA: Can You Run Both?

Running HPA (CPU%) and VPA (Auto) together on the same deployment creates a conflict: VPA changes the `requests` (the denominator in HPA's utilization formula), causing HPA to miscalculate.

### Safe combination rules

| Combination | Safe? | Notes |
| ----------- | ----- | ----- |
| HPA (CPU%) + VPA (Auto) | **No** | VPA changing requests breaks HPA utilization math |
| HPA (CPU%) + VPA (Off/Initial) | **Yes** | VPA recommends; you apply manually to the Deployment |
| HPA (custom metric, e.g. RPS) + VPA (Auto) | **Yes** | HPA doesn't use requests; no conflict |
| HPA (memory AverageValue) + VPA (Auto) | **No** | Same conflict as CPU% |

The recommended pattern for most workloads:

```text
Use VPA (Off) to right-size the Deployment's requests → then use HPA on CPU%
```

---

## Lab — HPA in Practice

### Setup

```bash
# Confirm Metrics Server is running
kubectl top pods -n inventory-service

# Deploy with resource requests (required for HPA)
kubectl apply -f kuberneters-manifests/
```

### Create and Watch

```bash
# Apply the HPA
kubectl apply -f kubernetes-manifests/hpa-inventory.yaml

# Current state — low load, at minReplicas
kubectl get hpa part-inventory-hpa -n inventory-service

# Port-forward and generate load
kubectl port-forward svc/part-inventory-service 8080:80 -n inventory-service &

# Load generator (runs 50 concurrent requests)
for i in $(seq 1 50); do
  while true; do
    curl -s http://localhost:8080/api/parts > /dev/null
  done &
done

# Watch the scale-out
watch kubectl get hpa part-inventory-hpa -n inventory-service
watch kubectl get pods -n inventory-service
```

### Cleanup

```bash
# Kill background curl jobs
kill %1 %2 %3   # or: kill $(jobs -p)

# HPA will scale back down after 5 minutes
# Force scale-down immediately:
kubectl patch hpa part-inventory-hpa -n inventory-service \
  --patch '{"spec":{"minReplicas":2}}'
```

---

## Verification Commands

```bash
# List all HPAs with targets and replica counts
kubectl get hpa -A

# Event history (scale decisions with reasons)
kubectl describe hpa part-inventory-hpa -n inventory-service

# Current resource usage (requires Metrics Server)
kubectl top pods -n inventory-service
kubectl top pods -n order-service

# VPA recommendations
kubectl describe vpa -n inventory-service

# HPA conditions (why it's not scaling)
kubectl get hpa part-inventory-hpa -n inventory-service -o yaml | grep -A20 conditions
```

---

## Common Issues

| Issue | Symptom | Fix |
| ----- | ------- | --- |
| HPA shows `<unknown>/50%` for CPU | Metrics not available | Metrics Server not running; `kubectl top pods` will also fail |
| HPA stuck at minReplicas despite load | Target always shown as 0% | Container missing `resources.requests.cpu` |
| HPA scales up but not back down | Replicas stay at max | `scaleDown.stabilizationWindowSeconds` is large; wait or reduce it |
| VPA evicts pods unexpectedly | Pods restart frequently | VPA mode is `Auto`; switch to `Initial` to stop evictions |
| HPA + VPA conflict | HPA oscillates | Running HPA (CPU%) and VPA (Auto) together; separate them per the safe combination rules above |
| Load generator reaches minReplicas limit | HPA won't scale beyond maxReplicas | Expected — increase `maxReplicas` if load is legitimate |
