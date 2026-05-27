# Pod — The Smallest Deployable Unit

## What is a Pod?

> A **Pod** is the smallest unit in Kubernetes.
> It wraps one or more containers that share:

* Network (same IP)
* Storage
* Lifecycle

### Key Characteristics

* Has one IP
* Containers inside communicate via `localhost`
* Ephemeral (can die anytime)

---

## Example

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: asset-pod
spec:
  containers:
    - name: asset-container
      image: asset-service:1.0
```

---

## Important Rule

> You rarely create Pods directly in production.

Why?

* No auto-restart
* No scaling
* No rolling updates

Pods are usually managed by higher-level controllers.

---

# ReplicaSet — Keeps Pods Running

## What is a ReplicaSet?

> Ensures a specified number of identical Pods are running.

If one Pod dies → ReplicaSet creates another.

## Example

```yaml
apiVersion: apps/v1
kind: ReplicaSet
spec:
  replicas: 3
  selector:
    matchLabels:
      app: asset
```

---

## When to use it?

Almost never directly.

Because Deployments manage ReplicaSets for you.

---

# 3Deployment — The Most Used Object

## What is a Deployment?

> A Deployment manages ReplicaSets and provides:

* Rolling updates
* Rollbacks
* Version control

## Example

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: asset-deployment
spec:
  replicas: 3
  selector:
    matchLabels:
      app: asset
  template:
    metadata:
      labels:
        app: asset
    spec:
      containers:
        - name: asset
          image: asset-service:1.0
```

---

## What it gives you

✔ Rolling updates
✔ Rollback support
✔ Scaling
✔ High availability

---

## In Microservices

Every stateless microservice → Deployment.

---

# DaemonSet — One Pod Per Node

## What is a DaemonSet?

> Ensures **one Pod runs on every node**.

## Common Use Cases

* Log collectors (Fluentd)
* Monitoring agents (Prometheus Node Exporter)
* Security agents
* Networking plugins

---

## Example

```yaml
apiVersion: apps/v1
kind: DaemonSet
metadata:
  name: log-agent
```

---

## Mental Model

Deployment → “I want 3 copies”
DaemonSet → “I want 1 per node”

---

# Job — Run Once and Finish

## What is a Job?

> A Job runs a task **to completion**.

## Use Cases

* Database migration
* Data processing
* Batch tasks
* One-time initialization

---

## Example

```yaml
apiVersion: batch/v1
kind: Job
spec:
  template:
    spec:
      containers:
        - name: migration
          image: flyway-migration:1.0
      restartPolicy: Never
```

---

## Key Feature

You define:

* How many completions required
* Retry behavior

Once complete → Job ends.

---

# CronJob — Scheduled Jobs

## What is a CronJob?

> A Job that runs on a schedule.

## Example

```yaml
apiVersion: batch/v1
kind: CronJob
spec:
  schedule: "0 0 * * *"
  jobTemplate:
    spec:
      template:
        spec:
          containers:
            - name: backup
              image: db-backup:1.0
          restartPolicy: Never
```

---

## Use Cases

* Nightly DB backup
* Report generation
* Cleanup tasks
* Data sync jobs

---

# Side-by-Side Comparison

| Object     | Purpose                 | Lifecycle  | Typical Use           |
|------------|-------------------------|------------|-----------------------|
| Pod        | Basic container wrapper | Ephemeral  | Rarely direct         |
| ReplicaSet | Maintain pod count      | Continuous | Managed by Deployment |
| Deployment | Manage stateless apps   | Continuous | Microservices         |
| DaemonSet  | 1 per node              | Continuous | Agents                |
| Job        | Run once                | Finite     | Migration             |
| CronJob    | Scheduled               | Repeating  | Batch                 |

---

# Real-World Mapping

| Component           | Kubernetes Object |
|---------------------|-------------------|
| Spring Boot service | Deployment        |
| Config Server       | Deployment        |
| Zipkin              | Deployment        |
| Fluentd             | DaemonSet         |
| Flyway migration    | Job               |
| Nightly backup      | CronJob           |

---

```
Pod (base)
 ↑
ReplicaSet
 ↑
Deployment
```

Jobs & CronJobs are separate workload controllers.

---

# Summary

> Deployment runs services continuously.
> DaemonSet runs system-level agents.
> Job runs tasks once.
> CronJob runs tasks on schedule.



