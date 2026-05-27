# StatefulSets and Managing Stateful Applications

## What is a StatefulSet?

A **StatefulSet** is a Kubernetes workload API object designed for applications that need **stable, persistent identity** across Pod restarts. Unlike Deployments, where Pods are interchangeable and ephemeral, StatefulSet Pods each have a unique, sticky identity.

Use StatefulSets for: **databases, message queues, distributed storage systems** — anything that depends on per-instance state or stable network names (e.g., MySQL, PostgreSQL, Kafka, Zookeeper, Elasticsearch).

---

## StatefulSet vs. Deployment

| Aspect | Deployment | StatefulSet |
| --- | --- | --- |
| Pod names | Random (`app-7d4f9-xkbtz`) | Ordered, stable (`mysql-0`, `mysql-1`) |
| Pod identity | Interchangeable | Unique and sticky |
| Scaling order | All at once (parallel) | Ordered: 0 → 1 → 2 (scale up), 2 → 1 → 0 (scale down) |
| Storage | Shared PVC or ephemeral | Each Pod gets its own PVC (via `volumeClaimTemplates`) |
| Network identity | No stable hostname | Stable DNS via headless service |
| Use case | Stateless apps | Stateful apps (DBs, queues) |

---

## Key Properties of StatefulSets

### 1. Stable Pod Names

Pods are named `<statefulset-name>-<ordinal>`:

```text
mysql-0
mysql-1
mysql-2
```

This name is preserved across restarts. If `mysql-1` crashes and is rescheduled, it comes back as `mysql-1` on the same PVC — not with a new random name.

### 2. Stable Network Identity (via Headless Service)

StatefulSets require a **headless service** (`clusterIP: None`) to manage DNS. Each Pod gets a stable DNS entry:

```text
<pod-name>.<service-name>.<namespace>.svc.cluster.local
```

For example:

```text
mysql-0.mysql.default.svc.cluster.local
mysql-1.mysql.default.svc.cluster.local
mysql-2.mysql.default.svc.cluster.local
```

This allows other Pods to directly address a specific replica — critical for replication configuration in databases.

### 3. Ordered Deployment and Scaling

- **Scale up:** Pods start in order: `mysql-0` must be `Running` before `mysql-1` starts
- **Scale down:** Pods terminate in reverse order: `mysql-2` → `mysql-1` → `mysql-0`
- **Updates (RollingUpdate):** Also done in reverse ordinal order by default

This ensures the primary/master (typically `mysql-0`) is always the first up and last down.

### 4. Per-Pod Storage via volumeClaimTemplates

Instead of all Pods sharing one PVC, each Pod gets its own PVC, automatically provisioned and permanently bound to that Pod:

```yaml
volumeClaimTemplates:
  - metadata:
      name: mysql-data
    spec:
      accessModes:
        - ReadWriteOnce
      storageClassName: hostpath-retain
      resources:
        requests:
          storage: 5Gi
```

This creates:

```text
mysql-data-mysql-0   (PVC for mysql-0)
mysql-data-mysql-1   (PVC for mysql-1)
mysql-data-mysql-2   (PVC for mysql-2)
```

**PVCs are NOT deleted when the StatefulSet is deleted** — this protects data from accidental loss. You must delete PVCs manually.

---

## StatefulSet YAML Structure

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: mysql
spec:
  serviceName: mysql              # must match the headless service name
  replicas: 3
  selector:
    matchLabels:
      app: mysql
  template:
    metadata:
      labels:
        app: mysql
    spec:
      containers:
        - name: mysql
          image: mysql:8.0
          env:
            - name: MYSQL_ROOT_PASSWORD
              value: "password"
          ports:
            - containerPort: 3306
          volumeMounts:
            - name: mysql-data
              mountPath: /var/lib/mysql
          resources:
            requests:
              cpu: "200m"
              memory: "256Mi"
            limits:
              cpu: "500m"
              memory: "512Mi"
  volumeClaimTemplates:
    - metadata:
        name: mysql-data
      spec:
        accessModes:
          - ReadWriteOnce
        storageClassName: hostpath-retain
        resources:
          requests:
            storage: 5Gi
```

---

## Headless Service (Required)

The headless service (`clusterIP: None`) enables per-Pod DNS resolution. Without it, StatefulSet Pods cannot be individually addressed.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: mysql
spec:
  clusterIP: None          # makes it headless
  selector:
    app: mysql
  ports:
    - port: 3306
      targetPort: 3306
```

---

## Managing a StatefulSet

```bash
# Deploy
kubectl apply -f mysql-headless-svc.yml
kubectl apply -f mysql-statefulset.yaml    # service must exist first

# Check status
kubectl get statefulset mysql
kubectl get pods -l app=mysql             # shows mysql-0, mysql-1, mysql-2
kubectl get pvc                           # shows one PVC per pod

# Scale
kubectl scale statefulset mysql --replicas=1

# Delete (PVCs survive!)
kubectl delete statefulset mysql
kubectl get pvc                           # PVCs still exist
kubectl delete pvc -l app=mysql          # must delete PVCs manually
```

---

## StatefulSet Update Strategies

### RollingUpdate (default)

Pods are updated one at a time in reverse ordinal order (`mysql-2` first, `mysql-0` last):

```yaml
spec:
  updateStrategy:
    type: RollingUpdate
    rollingUpdate:
      partition: 0    # only update pods with ordinal >= partition
```

`partition` is useful for canary releases: set `partition: 2` to only update `mysql-2`, verify, then lower the partition.

### OnDelete

Pod is only updated when manually deleted — useful when you need fine-grained control:

```yaml
spec:
  updateStrategy:
    type: OnDelete
```

---

## Common Pitfalls

- **Never use a Deployment for MySQL** — multiple replicas sharing one `ReadWriteOnce` PVC will corrupt data. Use a StatefulSet (1 replica) or a StatefulSet with proper replication setup.
- **Delete the headless Service last** — other services use the DNS names it provides.
- **PVCs outlive StatefulSets by design** — always clean up PVCs explicitly after deleting a StatefulSet.
- **`imagePullPolicy: Always`** causes unnecessary pulls on every restart; prefer `IfNotPresent` with pinned image tags in production.

---

## Key Takeaways

- StatefulSets give Pods a stable name, stable storage, and stable network identity
- The headless service is mandatory — it enables per-Pod DNS
- `volumeClaimTemplates` auto-creates one PVC per Pod; PVCs persist after StatefulSet deletion
- Ordered start/stop protects primary/replica relationships in databases
- For a single-instance MySQL, a StatefulSet with `replicas: 1` is still better than a Deployment because the PVC stays bound to the same Pod identity on reschedule
