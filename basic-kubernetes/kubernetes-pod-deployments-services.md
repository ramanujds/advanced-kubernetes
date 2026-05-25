# Kubernetes: Pods, Deployments, and Services

## Pods

A **Pod** is the smallest deployable unit in Kubernetes. It wraps one or more containers that share the same network namespace and storage.

### Key Characteristics
- Each Pod gets its own cluster-internal IP address
- Containers inside a Pod communicate via `localhost`
- Pods are ephemeral — they are not self-healing; if a Pod dies, it is gone unless a controller (e.g., Deployment) recreates it
- A Pod can have init containers that run before the main container starts

### Pod Lifecycle States
| Phase | Meaning |
|-------|---------|
| `Pending` | Pod accepted, but container(s) not yet running (scheduling or image pull in progress) |
| `Running` | At least one container is running |
| `Succeeded` | All containers exited with code 0 (typical for Jobs) |
| `Failed` | All containers terminated, at least one with non-zero exit code |
| `Unknown` | Pod state cannot be determined (node communication issue) |

### Essential Pod Commands
```bash
# List pods in current namespace
kubectl get pods

# Detailed info (events, volumes, IPs, conditions)
kubectl describe pod <pod-name>

# Stream logs
kubectl logs -f <pod-name>

# Logs from a specific container in a multi-container pod
kubectl logs <pod-name> -c <container-name>

# Logs from previous (crashed) container instance
kubectl logs <pod-name> --previous

# Execute a command inside a running pod
kubectl exec -it <pod-name> -- /bin/sh

# Delete a pod (Deployment will recreate it)
kubectl delete pod <pod-name>
```

---

## Deployments

A **Deployment** manages a ReplicaSet, which in turn manages a set of identical Pods. It ensures the desired number of replicas are running and handles rolling updates and rollbacks.

### Key Characteristics
- Declarative — you describe the desired state; Kubernetes reconciles reality to match
- Supports rolling updates with configurable surge and unavailability limits
- Keeps a revision history so you can roll back
- Automatically replaces failed or evicted Pods

### Deployment Strategy Options
```yaml
strategy:
  type: RollingUpdate        # or Recreate
  rollingUpdate:
    maxSurge: 1              # extra pods allowed during update
    maxUnavailable: 0        # pods that can be down during update
```

### Essential Deployment Commands
```bash
# List deployments
kubectl get deployments

# Scale replicas
kubectl scale deployment <name> --replicas=3

# Update the container image (triggers rolling update)
kubectl set image deployment/<name> <container>=<image>:<tag>

# Watch rollout status
kubectl rollout status deployment/<name>

# View rollout history
kubectl rollout history deployment/<name>

# Roll back to previous revision
kubectl rollout undo deployment/<name>

# Roll back to a specific revision
kubectl rollout undo deployment/<name> --to-revision=2

# Pause / resume a rollout
kubectl rollout pause deployment/<name>
kubectl rollout resume deployment/<name>
```

---

## Services

A **Service** gives a stable network endpoint to a dynamic set of Pods. It uses label selectors to determine which Pods receive traffic.

### Service Types

| Type | Description |
|------|-------------|
| `ClusterIP` | Default. Exposes the service on a cluster-internal IP. Only reachable within the cluster. |
| `NodePort` | Exposes the service on each Node's IP at a static port (30000–32767). Reachable from outside the cluster. |
| `LoadBalancer` | Provisions an external load balancer (cloud provider). Gives the service a public IP. |
| `ExternalName` | Maps a service to an external DNS name (no proxying, just CNAME). |

### How Services Find Pods
Services use `selector` labels to route traffic to matching Pods. The Pod must have all the labels listed in the selector.

```yaml
# Service selector
selector:
  app: my-app

# Pod labels (must include app: my-app to receive traffic)
labels:
  app: my-app
  version: v1
```

### DNS Resolution Inside the Cluster
Kubernetes DNS resolves service names automatically:
- Same namespace: `my-service`
- Cross-namespace: `my-service.my-namespace`
- Full FQDN: `my-service.my-namespace.svc.cluster.local`

### Essential Service Commands
```bash
# List services
kubectl get services

# Describe a service (see endpoints, selector, ports)
kubectl describe service <name>

# Check which pods a service is routing to
kubectl get endpoints <name>

# Temporarily expose a deployment (for testing)
kubectl expose deployment <name> --type=NodePort --port=80

# Port-forward a service to localhost
kubectl port-forward service/<name> 8080:80
```

---

## Labels and Selectors

Labels are key-value pairs attached to resources. Selectors filter resources by label.

```bash
# Filter pods by label
kubectl get pods -l app=my-app

# Add a label to a running pod
kubectl label pod <pod-name> env=staging

# Remove a label
kubectl label pod <pod-name> env-
```

---

## Namespaces

Namespaces provide logical isolation within a cluster.

```bash
# List all namespaces
kubectl get namespaces

# Run commands in a specific namespace
kubectl get pods -n kube-system

# Set a default namespace for your current context
kubectl config set-context --current --namespace=my-namespace
```
