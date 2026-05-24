# Advanced Resource Requests and Limits Management

## Why Resource Configuration Matters

Kubernetes schedules pods based on `requests` and enforces behaviour under pressure using `limits`. Getting these wrong causes the most common production incidents:

```text
requests too low  → pod scheduled on a full node → throttled or OOMKilled
requests too high → pod wastes reserved capacity → cluster fills up prematurely
limits too low    → CPU throttled at normal load, or OOMKilled on burst
limits too high   → noisy-neighbour problem, node instability
no requests set   → HPA cannot compute CPU%, scheduler makes poor placement decisions
```

---

## Requests vs Limits — What They Actually Do

| Field | Scheduler sees | Kernel enforces |
| ----- | -------------- | --------------- |
| `requests.cpu` | "Reserve this much CPU on a node" | Nothing — it's a scheduling hint |
| `limits.cpu` | Nothing | Kernel throttles via CFS quota — process slows, never killed |
| `requests.memory` | "Reserve this much memory on a node" | Nothing — it's a scheduling hint |
| `limits.memory` | Nothing | OOMKiller kills the container when exceeded |

CPU is **compressible**: a container that hits its CPU limit is throttled (slowed down).
Memory is **incompressible**: a container that exceeds its memory limit is killed (OOMKilled, exit code 137).

```bash
# See what a node has scheduled vs what it has allocatable
kubectl describe node advanced-k8s-m02
# Allocatable:
#   cpu:     3800m
#   memory:  7800Mi
# Allocated resources:
#   cpu requests: 2200m / 3800m (57%)
#   cpu limits:   4000m / 3800m (105%)   ← limits can exceed allocatable (overcommit)
#   memory requests: 3200Mi / 7800Mi (41%)
#   memory limits:   5000Mi / 7800Mi (64%)
```

Memory limits can exceed node allocatable (overcommit), but when the node runs out of actual memory the OOMKiller evicts pods — highest-memory containers first.

---

## QoS Classes: How Kubernetes Decides What to Kill

Every pod is assigned a QoS class based on its resource spec. Under memory pressure, Kubernetes evicts pods in this order:

```text
BestEffort  ← evicted first (no requests or limits set)
    ↓
Burstable   ← evicted next (requests set but limits != requests, or only one is set)
    ↓
Guaranteed  ← evicted last (requests == limits for ALL containers)
```

### Guaranteed QoS

```yaml
# requests == limits for EVERY container, both cpu and memory
resources:
  requests:
    cpu: "500m"
    memory: "512Mi"
  limits:
    cpu: "500m"
    memory: "512Mi"
```

Use for: critical services (`part-inventory-service`, `part-order-service`), databases.

### Burstable QoS

```yaml
# requests set, limits higher — pod can burst above its reservation
resources:
  requests:
    cpu: "250m"
    memory: "256Mi"
  limits:
    cpu: "1000m"
    memory: "1Gi"
```

Use for: most application workloads. Pod gets consistent minimum resources but can burst when the node has headroom.

### BestEffort QoS

```yaml
# No resources block at all — or empty
resources: {}
```

Avoid in production. These pods are the first evicted under any memory pressure.

```bash
# Check the QoS class of each pod
kubectl get pods -n inventory-service -o custom-columns=\
"NAME:.metadata.name,QOS:.status.qosClass"
# NAME                              QOS
# part-inventory-service-xxxx       Burstable
```

---

## Right-Sizing: Finding the Correct Values

### Step 1 — Observe actual usage

```bash
# Current snapshot
kubectl top pods -n inventory-service
# NAME                              CPU(cores)   MEMORY(bytes)
# part-inventory-service-abc        48m          210Mi

# Historical — requires Prometheus
# Query: container_cpu_usage_seconds_total (rate over 5m)
# Query: container_memory_working_set_bytes
```

### Step 2 — Use VPA recommendations (safest method)

```bash
# Deploy VPA in Off mode (observe only, no changes)
kubectl apply -f - <<EOF
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
    updateMode: "Off"
EOF

# After 24–48 hours under real traffic, read the recommendation
kubectl describe vpa part-inventory-vpa -n inventory-service
# Target:
#   Cpu:     320m     ← set requests.cpu to this
#   Memory:  384Mi    ← set requests.memory to this
```

### Step 3 — Apply the recommendation

```yaml
resources:
  requests:
    cpu: "320m"
    memory: "384Mi"
  limits:
    cpu: "1000m"       # 3× requests — room to burst
    memory: "512Mi"    # tighter than CPU; OOMKill is harder to debug than throttle
```

A rule of thumb for limits:

- CPU limit = 2–4× CPU request (burst room, throttle is recoverable)
- Memory limit = 1.5–2× memory request (tighter; OOMKill is disruptive)

---

## LimitRange: Set Defaults for a Namespace

A `LimitRange` sets default requests and limits for every pod in a namespace that does not specify them. Prevents BestEffort QoS pods from entering the cluster accidentally.

```yaml
apiVersion: v1
kind: LimitRange
metadata:
  name: inventory-defaults
  namespace: inventory-service
spec:
  limits:
    - type: Container
      default:                   # applied as limits when not specified
        cpu: "500m"
        memory: "512Mi"
      defaultRequest:            # applied as requests when not specified
        cpu: "100m"
        memory: "128Mi"
      max:                       # hard ceiling — pod rejected if it exceeds this
        cpu: "2"
        memory: "2Gi"
      min:                       # floor — pod rejected if below this
        cpu: "50m"
        memory: "64Mi"
```

```bash
kubectl apply -f kubernetes-manifests/limitrange-inventory.yaml

# Verify — create a pod without resources and check what it gets
kubectl run test-pod --image=nginx -n inventory-service --restart=Never
kubectl get pod test-pod -n inventory-service -o json | jq '.spec.containers[0].resources'
# {
#   "limits": { "cpu": "500m", "memory": "512Mi" },
#   "requests": { "cpu": "100m", "memory": "128Mi" }
# }

kubectl delete pod test-pod -n inventory-service
```

---

## ResourceQuota: Cap Total Namespace Consumption

A `ResourceQuota` limits the total resources all pods in a namespace can consume. Prevents one team's namespace from starving others.

```yaml
apiVersion: v1
kind: ResourceQuota
metadata:
  name: inventory-quota
  namespace: inventory-service
spec:
  hard:
    requests.cpu: "4"          # total CPU requests across all pods
    requests.memory: "4Gi"     # total memory requests
    limits.cpu: "8"            # total CPU limits
    limits.memory: "8Gi"       # total memory limits
    pods: "20"                 # max pod count
    persistentvolumeclaims: "5"
```

```bash
kubectl apply -f kubernetes-manifests/resourcequota-inventory.yaml

# Check current consumption vs quota
kubectl describe resourcequota inventory-quota -n inventory-service
# Resource              Used    Hard
# ────────────────────────────────────
# limits.cpu            1500m   8
# limits.memory         2Gi     8Gi
# pods                  3       20
# requests.cpu          750m    4
# requests.memory       1Gi     4Gi
```

When the namespace is at quota, new pods are rejected with:
`Error from server (Forbidden): pods "..." is forbidden: exceeded quota`

---

## CPU Throttling: The Silent Performance Killer

CPU throttling does not appear in pod logs or events. It manifests as unexplained latency increases.

### Detect throttling

```bash
# Check CFS throttling metrics via Prometheus
# container_cpu_cfs_throttled_seconds_total / container_cpu_cfs_periods_total

# Or check directly from the kubelet metrics endpoint
kubectl exec -n inventory-service <pod-name> -- cat /sys/fs/cgroup/cpu/cpu.stat
# nr_periods 1200
# nr_throttled 340          ← 28% of scheduling periods were throttled
# throttled_time 8400000000 ← 8.4 seconds of throttle time
```

### Fix throttling

Option 1 — Raise the CPU limit:

```yaml
limits:
  cpu: "1500m"   # was 500m — increase until throttling drops
```

Option 2 — Remove the CPU limit entirely (controversial but effective):

```yaml
resources:
  requests:
    cpu: "250m"    # keep requests for scheduling accuracy
  # no limits.cpu  → pod can use spare node CPU freely
```

Without a CPU limit, the pod is still governed by the scheduler's bin-packing (it only gets scheduled on nodes with enough capacity for the request). The kernel's CFS fair-share scheduler naturally limits each container's share when the node is busy.

---

## Memory: Avoiding OOMKill

OOMKill produces `exit code 137` and `OOMKilled` in `kubectl describe pod`.

```bash
# Check if a pod was OOMKilled
kubectl describe pod <pod-name> -n inventory-service | grep -A5 "Last State"
# Last State: Terminated
#   Reason:   OOMKilled
#   Exit Code: 137

# Check memory usage trend before the OOMKill
kubectl top pods -n inventory-service   # current
```

### Causes and fixes

| Cause | Fix |
| ----- | --- |
| Memory limit set too low | Increase limit; use VPA to find the right value |
| Memory leak in application | Profile the app — scaling the limit hides the problem |
| Startup memory spike (JVM) | Set higher `limits.memory`; use Spring Boot's `-Xms`/`-Xmx` flags |
| Cache growth unbounded | Add eviction policy in app, or set limits.memory and accept OOMKill as a restart trigger |

### JVM heap sizing for part-inventory-service

The JVM's default heap is 25% of container memory. For a pod with 512Mi memory limit:

```yaml
env:
  - name: JAVA_OPTS
    value: "-Xms128m -Xmx384m"   # 75% of 512Mi limit
    # Leaves ~128Mi for non-heap (Metaspace, threads, off-heap)
```

Without explicit `-Xmx`, the JVM sizes heap based on the host node's memory (not the container limit), which leads to OOMKill.

---

## Priority Classes: Who Gets Resources When the Cluster Is Full

PriorityClasses determine which pods get scheduled first and which are evicted last.

```yaml
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: high-priority
value: 1000000
globalDefault: false
description: "Critical production services"
---
apiVersion: scheduling.k8s.io/v1
kind: PriorityClass
metadata:
  name: low-priority
value: 100
globalDefault: false
description: "Batch jobs and non-critical workloads"
```

```yaml
# Apply to part-inventory-service
spec:
  priorityClassName: high-priority
  containers:
    - name: part-inventory-service
```

```yaml
# Apply to a batch job
spec:
  priorityClassName: low-priority
  containers:
    - name: batch-processor
```

When the cluster is full and a high-priority pod needs to be scheduled, the scheduler evicts low-priority pods to make room (**preemption**).

---

## Lab — Observe Throttling and OOMKill

### Trigger CPU throttling

```bash
# Deploy part-inventory-service with artificially low CPU limit
kubectl patch deployment part-inventory-service -n inventory-service \
  --patch '{"spec":{"template":{"spec":{"containers":[{
    "name":"part-inventory-service",
    "resources":{"limits":{"cpu":"50m"}}
  }]}}}}'

# Generate load — watch latency increase due to throttling
kubectl port-forward svc/part-inventory-service 8080:80 -n inventory-service &
for i in $(seq 1 20); do
  time curl -s http://localhost:8080/api/parts > /dev/null
done

# Check throttle stat
POD=$(kubectl get pods -n inventory-service -l app=part-inventory-service -o name | head -1)
kubectl exec -n inventory-service $POD -- cat /sys/fs/cgroup/cpu/cpu.stat

# Restore
kubectl rollout undo deployment/part-inventory-service -n inventory-service
```

### Trigger OOMKill

```bash
# Set memory limit below actual usage
kubectl patch deployment part-inventory-service -n inventory-service \
  --patch '{"spec":{"template":{"spec":{"containers":[{
    "name":"part-inventory-service",
    "resources":{"limits":{"memory":"64Mi"}}
  }]}}}}'

# Wait for the pod to start — JVM alone needs more than 64Mi
kubectl get pods -n inventory-service -w
# part-inventory-service-xxxx   0/1   OOMKilled   1   10s

kubectl describe pod -n inventory-service -l app=part-inventory-service | grep -A5 "Last State"

# Restore
kubectl rollout undo deployment/part-inventory-service -n inventory-service
```

---

## Verification Commands

```bash
# Resource usage per pod
kubectl top pods -n inventory-service
kubectl top pods -n order-service

# Resource usage per node
kubectl top nodes

# QoS class for all pods
kubectl get pods -A -o custom-columns="NS:.metadata.namespace,NAME:.metadata.name,QOS:.status.qosClass"

# Node allocatable vs allocated
kubectl describe nodes | grep -A8 "Allocated resources"

# LimitRange in a namespace
kubectl get limitrange -n inventory-service
kubectl describe limitrange inventory-defaults -n inventory-service

# ResourceQuota usage
kubectl describe resourcequota inventory-quota -n inventory-service

# OOMKill history
kubectl get events -A | grep OOMKill
```
