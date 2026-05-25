# Kubernetes Debugging and Troubleshooting

## General Debugging Workflow

```
kubectl get pods          →  spot the bad pod
kubectl describe pod      →  read Events section at the bottom
kubectl logs              →  read container output
kubectl exec -it          →  get a shell and investigate from inside
```

---

## Common Pod Errors

### ImagePullBackOff / ErrImagePull

**Symptoms:** Pod stuck in `ImagePullBackOff` or `ErrImagePull`.

**Causes:**
- Image name or tag is wrong
- Image is private and no pull secret is configured
- Registry is unreachable from the cluster

**Fix:**
```bash
kubectl describe pod <pod-name>
# Look at Events — shows the exact pull error

# Verify the image exists
docker pull <image>:<tag>

# If private registry, create a pull secret
kubectl create secret docker-registry regcred \
  --docker-server=<registry> \
  --docker-username=<user> \
  --docker-password=<password>

# Reference it in the pod spec
# imagePullSecrets:
#   - name: regcred
```

---

### CrashLoopBackOff

**Symptoms:** Pod repeatedly crashes; restart count keeps climbing.

**Causes:**
- Application exits with a non-zero code (misconfiguration, missing env var, bug)
- Liveness probe fails immediately
- OOMKilled (out of memory)

**Fix:**
```bash
# Read logs from the last crashed instance
kubectl logs <pod-name> --previous

# Check exit reason and OOM
kubectl describe pod <pod-name>
# Look for: Last State, Exit Code, Reason: OOMKilled

# Common fixes:
# - Correct env vars / secrets
# - Increase memory limits
# - Fix liveness probe thresholds (initialDelaySeconds too low)
```

---

### Pending — Pod Won't Schedule

**Symptoms:** Pod stays in `Pending` indefinitely.

**Causes:**
- Not enough CPU/memory on any node
- Node selector or affinity rules match no nodes
- Taint on all nodes with no matching toleration
- PersistentVolumeClaim not bound

**Fix:**
```bash
kubectl describe pod <pod-name>
# Events will say: "0/3 nodes are available: insufficient memory" etc.

# Check node resources
kubectl describe nodes | grep -A 5 "Allocated resources"

# Check PVC status
kubectl get pvc

# Check taints
kubectl describe nodes | grep Taint
```

---

### OOMKilled

**Symptoms:** Container is killed; `kubectl describe` shows `Reason: OOMKilled`, exit code 137.

**Fix:**
```bash
kubectl describe pod <pod-name>
# Look for: Reason: OOMKilled under Last State

# Increase memory limit in the deployment
kubectl set resources deployment <name> \
  --limits=memory=512Mi
```

---

### Pod Running but Not Reachable via Service

**Symptoms:** Service exists, but requests time out or connection is refused.

**Causes:**
- Label selector on Service doesn't match Pod labels
- Pod not listening on the declared `containerPort`
- NetworkPolicy blocking traffic

**Fix:**
```bash
# Check if service has endpoints (empty = selector mismatch)
kubectl get endpoints <service-name>

# Compare selector vs pod labels
kubectl describe service <service-name>   # shows Selector
kubectl get pod <pod-name> --show-labels  # shows labels

# Test connectivity from inside the cluster
kubectl run tmp --image=busybox --restart=Never -it --rm \
  -- wget -qO- http://<service-name>:<port>

# Port-forward directly to the pod (bypasses service)
kubectl port-forward pod/<pod-name> 8080:8080
```

---

### Node Not Ready

**Symptoms:** `kubectl get nodes` shows `NotReady`.

**Fix:**
```bash
kubectl describe node <node-name>
# Check Conditions and Events

# Common causes:
# - kubelet not running on the node
# - Disk pressure (DiskPressure condition = True)
# - Memory pressure (MemoryPressure condition = True)
# - Network plugin (CNI) issue

# SSH into node and check kubelet
systemctl status kubelet
journalctl -u kubelet -n 50
```

---

### ConfigMap / Secret Not Mounted

**Symptoms:** App crashes because expected config file or env var is missing.

**Fix:**
```bash
# Verify the ConfigMap or Secret exists
kubectl get configmap <name>
kubectl get secret <name>

# Check what's inside
kubectl describe configmap <name>
kubectl get secret <name> -o jsonpath='{.data}'

# Verify the pod spec references the right name and key
kubectl describe pod <pod-name>
# Under Environment or Mounts
```

---

### Liveness/Readiness Probe Failing

**Symptoms:** Pod restarts frequently (liveness) or never receives traffic (readiness).

**Fix:**
```bash
kubectl describe pod <pod-name>
# Look for: Liveness probe failed / Readiness probe failed in Events

# Common fixes:
# - Increase initialDelaySeconds (app takes time to start)
# - Check the probe path/port matches what the app actually serves
# - Test the probe endpoint manually:
kubectl exec -it <pod-name> -- wget -qO- http://localhost:8080/actuator/health
```

---

## Useful Debugging One-Liners

```bash
# Get all pods across all namespaces with their status
kubectl get pods -A

# Watch pod status in real time
kubectl get pods -w

# Describe all events sorted by time (cluster-wide)
kubectl get events --sort-by='.lastTimestamp' -A

# Get resource usage per pod (requires metrics-server)
kubectl top pods
kubectl top nodes

# Find pods that are not Running
kubectl get pods -A --field-selector=status.phase!=Running

# Delete a stuck Terminating pod (force)
kubectl delete pod <pod-name> --grace-period=0 --force

# Copy a file out of a pod
kubectl cp <pod-name>:/path/to/file ./local-file

# Run a temporary debug container
kubectl run debug --image=busybox --restart=Never -it --rm -- /bin/sh

# Check if a service DNS resolves from inside a pod
kubectl exec -it <pod-name> -- nslookup <service-name>
```

---

## Reading `kubectl describe pod` — Key Sections

```
State:          current container state
Last State:     previous run (shows why it crashed)
Exit Code:      0 = clean exit, non-zero = error, 137 = OOMKilled, 143 = SIGTERM
Restart Count:  how many times it has crashed
Conditions:     PodScheduled, ContainersReady, Ready
Events:         most useful — shows pull errors, probe failures, scheduling failures
```
