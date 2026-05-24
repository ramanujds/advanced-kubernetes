## Custom Resource Definitions (CRDs) in Kubernetes

### The Core Problem CRDs Solve

Kubernetes ships with built-in resources like `Pod`, `Deployment`, and `Service`. But real-world applications often need abstractions that don't exist natively. CRDs let you **extend the Kubernetes API** with your own resource types, so you can manage custom application concepts the same way you manage native resources.

---

### Without CRDs — The Problem

Imagine you're deploying a PostgreSQL database. You'd need to manually manage:

- A `StatefulSet` for the pods
- A `Service` for networking
- A `ConfigMap` for config
- A `Secret` for credentials
- `PersistentVolumeClaims` for storage
- Custom backup logic via CronJobs

That's 5+ objects just to run one database. Now multiply that across 50 teams.

---

### With a CRD — The Solution

You define a single `PostgresCluster` resource:

```yaml
apiVersion: postgres.example.com/v1
kind: PostgresCluster
metadata:
  name: my-db
spec:
  replicas: 3
  storage: 100Gi
  backupSchedule: "0 2 * * *"
  version: "15"
```

An **operator** (a controller watching this CRD) then automatically creates and manages all the underlying objects. One resource, full lifecycle management.

---

### How a CRD is Defined

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: postgresclusters.postgres.example.com
spec:
  group: postgres.example.com
  versions:
    - name: v1
      served: true
      storage: true
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              properties:
                replicas:
                  type: integer
                storage:
                  type: string
  scope: Namespaced
  names:
    plural: postgresclusters
    singular: postgrescluster
    kind: PostgresCluster
```

Once applied, `kubectl get postgresclusters` works just like `kubectl get pods`.

---

### Real-World Use Cases

| Use Case | CRD | Popular Operator |
|---|---|---|
| **Databases** | `PostgresCluster`, `MysqlCluster` | CloudNativePG, Percona |
| **Message queues** | `Kafka`, `KafkaTopic` | Strimzi |
| **Certificates** | `Certificate`, `Issuer` | cert-manager |
| **Service mesh** | `VirtualService`, `DestinationRule` | Istio |
| **ML workloads** | `PyTorchJob`, `TFJob` | Kubeflow |
| **GitOps** | `Application`, `GitRepository` | ArgoCD, Flux |
| **Monitoring** | `PrometheusRule`, `ServiceMonitor` | Prometheus Operator |

---

### Why CRDs Are Better Than Alternatives

**vs. ConfigMaps for config** — ConfigMaps have no schema validation, no versioning, no status fields. CRDs give you typed, validated, versioned resources with `spec` + `status` separation.

**vs. Helm alone** — Helm installs resources but doesn't actively manage them. A CRD + operator *continuously reconciles* — if someone deletes a resource by accident, the operator recreates it.

**vs. External scripts** — Scripts run once. Operators run a continuous control loop, reacting to drift, failures, and changes automatically.

---

### The Operator Pattern (CRDs in Action)

```
User applies CRD instance
        ↓
API Server stores it (etcd)
        ↓
Controller/Operator watches for changes
        ↓
Reconcile loop runs → creates/updates/deletes child resources
        ↓
Updates .status on the CRD (health, phase, errors)
```

You can then inspect state with:
```bash
kubectl get postgrescluster my-db -o yaml
# .status.phase: Running
# .status.readyReplicas: 3
```

---

### Key Benefits Summary

- **Kubernetes-native UX** — `kubectl get/apply/delete` works on your custom types
- **RBAC integration** — you can grant/deny access to your CRDs just like built-in resources
- **Schema validation** — OpenAPI v3 schema rejects bad configs at apply time
- **GitOps friendly** — CRD instances are just YAML, easily stored in Git
- **Lifecycle automation** — paired with an operator, complex Day-2 operations (backups, upgrades, failover) become declarative

CRDs are essentially how the Kubernetes ecosystem extends itself — nearly every major cloud-native tool (Istio, ArgoCD, Prometheus, cert-manager) is built on them.