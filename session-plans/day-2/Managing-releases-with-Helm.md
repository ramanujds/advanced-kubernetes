# Managing Releases and Rollbacks with Helm

## How Helm Tracks Releases

Every `helm install` or `helm upgrade` creates a **revision** — a numbered snapshot of the full chart render (all manifests + values) stored as a Kubernetes Secret in the release namespace.

```bash
# Helm stores release history as Secrets
kubectl get secrets -n inventory-service | grep helm
# sh.helm.release.v1.parts.v1   helm.sh/release.v1   1   5m
# sh.helm.release.v1.parts.v2   helm.sh/release.v1   1   2m
# sh.helm.release.v1.parts.v3   helm.sh/release.v1   1   1m
```

Each Secret is a complete, self-contained record of that revision — Helm can roll back to any of them without needing the original chart files.

---

## Release Lifecycle Commands

### install — create a release for the first time

```bash
helm install parts ./inventory-order-app-chart \
  --namespace inventory-service \
  --create-namespace \
  --values values-dev.yaml

# --create-namespace creates the namespace if it doesn't exist
# Release name: parts
# Chart:        ./inventory-order-app-chart
```

### upgrade — apply changes to an existing release

```bash
# Upgrade with a new image tag
helm upgrade parts ./inventory-order-app-chart \
  --namespace inventory-service \
  --values values-dev.yaml \
  --set partInventory.image.tag=v2

# upgrade --install: installs if not present, upgrades if present
# Useful in CI pipelines where you don't know whether the release exists
helm upgrade --install parts ./inventory-order-app-chart \
  --namespace inventory-service \
  --values values-dev.yaml
```

### rollback — revert to a previous revision

```bash
# Roll back to revision 1
helm rollback parts 1 --namespace inventory-service

# Roll back one revision (to the previous)
helm rollback parts --namespace inventory-service
```

### uninstall — remove the release and all its resources

```bash
helm uninstall parts --namespace inventory-service

# Keep history after uninstall (allows rollback to reinstall)
helm uninstall parts --namespace inventory-service --keep-history
```

---

## Inspecting Releases

```bash
# All releases across all namespaces
helm list -A

# Releases in a specific namespace including failed/pending states
helm list -n inventory-service --all

# Release history — all revisions with status and description
helm history parts -n inventory-service
# REVISION  UPDATED             STATUS      CHART                    DESCRIPTION
# 1         2026-05-26 09:00    superseded  inv-order-app-0.1.0      Install complete
# 2         2026-05-26 09:15    superseded  inv-order-app-0.1.0      Upgrade complete
# 3         2026-05-26 09:20    deployed    inv-order-app-0.1.0      Rollback to 1

# Current release status
helm status parts -n inventory-service

# Rendered manifests currently deployed (what's actually in the cluster)
helm get manifest parts -n inventory-service

# Effective values (merged defaults + your overrides)
helm get values parts -n inventory-service

# All values including defaults
helm get values parts -n inventory-service --all

# Specific revision's manifests
helm get manifest parts -n inventory-service --revision 1
```

---

## Lab — Upgrade and Rollback the Parts Application

### Setup: install revision 1

```bash
# Install the chart from the inventory-order-app-chart directory
helm install parts ./inventory-order-app-chart \
  --namespace inventory-service \
  --create-namespace

# Confirm everything is running
helm status parts -n inventory-service
kubectl get pods -n inventory-service
# NAME                                    READY   STATUS
# part-inventory-service-xxxx             1/1     Running
# part-order-service-xxxx                 1/1     Running
```

### Upgrade to v2: revision 2

```bash
# Bump the inventory image tag to v2
helm upgrade parts ./inventory-order-app-chart \
  --namespace inventory-service \
  --set partInventory.image.tag=v2

# Watch the rolling update
kubectl rollout status deployment/part-inventory-service -n inventory-service
# Waiting for deployment "part-inventory-service" rollout to finish...
# deployment "part-inventory-service" successfully rolled out

# Confirm revision 2 is deployed
helm history parts -n inventory-service
```

### Simulate a bad upgrade: revision 3

```bash
# Upgrade with a non-existent image tag — pods will ImagePullBackOff
helm upgrade parts ./inventory-order-app-chart \
  --namespace inventory-service \
  --set partInventory.image.tag=does-not-exist

# Observe the failure
kubectl get pods -n inventory-service -w
# NAME                                    READY   STATUS
# part-inventory-service-xxxx (old)       1/1     Running    ← still serving traffic
# part-inventory-service-yyyy (new)       0/1     ImagePullBackOff

# Helm marks the release deployed regardless — it does not wait by default
helm history parts -n inventory-service
# REVISION 3  STATUS: deployed   ← Helm says deployed even though pods are failing
```

### Roll back to revision 2

```bash
# Roll back to the last known good revision
helm rollback parts 2 -n inventory-service

# Helm applies revision 2's manifests — Kubernetes rolls out the old image
kubectl rollout status deployment/part-inventory-service -n inventory-service

# Verify
helm history parts -n inventory-service
# REVISION  STATUS
# 1         superseded
# 2         superseded
# 3         superseded
# 4         deployed     ← rollback is a new revision, not a rewind
```

Rollback creates a new revision (4) rather than reverting to 2. The history is always append-only.

---

## Atomic Upgrades: Fail Fast and Auto-Rollback

The default `helm upgrade` does not wait for pods to become healthy. `--atomic` makes it wait and roll back automatically on failure:

```bash
helm upgrade parts ./inventory-order-app-chart \
  --namespace inventory-service \
  --set partInventory.image.tag=does-not-exist \
  --atomic \
  --timeout 3m

# --atomic: waits for all pods to be Ready; rolls back if timeout exceeded
# --timeout: how long to wait before declaring failure (default: 5m)

# Output when it fails:
# UPGRADE FAILED: release parts failed, and has been rolled back
# due to atomic being set: timed out waiting for the condition

# History after --atomic failure — revision 3 is rolled back, not deployed
helm history parts -n inventory-service
# REVISION  STATUS
# 1         superseded
# 2         deployed    ← automatic rollback restored this
# 3         failed
```

Use `--atomic` in CI/CD pipelines where you want automatic recovery from bad deployments.

---

## Upgrade with Diff Preview

Before applying an upgrade, see exactly what will change using the `helm-diff` plugin:

```bash
# Install the diff plugin
helm plugin install https://github.com/databus23/helm-diff

# Preview what revision 3 would change vs the current deployed state
helm diff upgrade parts ./inventory-order-app-chart \
  --namespace inventory-service \
  --set partInventory.image.tag=v3

# Output (unified diff format):
# inventory-service/Deployment/part-inventory-service
#   ...
#   -         image: ram1uj/part-inventory-service:v2
#   +         image: ram1uj/part-inventory-service:v3
```

This is the Helm equivalent of `kubectl diff` — critical for reviewing changes before a production upgrade.

---

## Managing Multiple Environments

Use the same chart with per-environment values files:

```bash
# dev — single replica, no autoscaling, dev profile
helm upgrade --install parts-dev ./inventory-order-app-chart \
  --namespace inventory-dev \
  --create-namespace \
  --values values-dev.yaml

# staging — 2 replicas, staging profile, staging MySQL
helm upgrade --install parts-staging ./inventory-order-app-chart \
  --namespace inventory-staging \
  --create-namespace \
  --values values-staging.yaml

# prod — autoscaling enabled, higher resources, prod MySQL, prod image tag
helm upgrade --install parts-prod ./inventory-order-app-chart \
  --namespace inventory-prod \
  --create-namespace \
  --values values-prod.yaml \
  --set partInventory.image.tag=1.4.2 \
  --set partOrder.image.tag=1.4.2
```

Each environment is a separate Helm release — upgrades and rollbacks are independent.

```bash
# Promote the same image from staging to prod after testing
STAGING_TAG=$(helm get values parts-staging -n inventory-staging | grep "tag:" | awk '{print $2}')

helm upgrade parts-prod ./inventory-order-app-chart \
  --namespace inventory-prod \
  --values values-prod.yaml \
  --set partInventory.image.tag=$STAGING_TAG \
  --atomic
```

---

## Revision Retention and Cleanup

By default Helm keeps 10 revisions. Old revisions accumulate as Secrets in the namespace.

```bash
# Set max history at install time
helm install parts ./inventory-order-app-chart \
  --namespace inventory-service \
  --history-max 5

# Or globally via HELM_MAX_HISTORY env var
export HELM_MAX_HISTORY=5
```

Keeping fewer revisions reduces Secret clutter but limits how far back you can roll back.

---

## Hooks: Run Jobs at Lifecycle Points

Helm hooks let you run Kubernetes Jobs or other resources at specific points in the release lifecycle — before/after install, upgrade, rollback, or delete.

```yaml
# templates/db-migrate-job.yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: db-migrate
  annotations:
    "helm.sh/hook": pre-upgrade          # run before the upgrade manifests are applied
    "helm.sh/hook-weight": "-5"          # run earlier than weight 0 hooks
    "helm.sh/hook-delete-policy": before-hook-creation,hook-succeeded
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: db-migrate
          image: "{{ .Values.partInventory.image.repository }}:{{ .Values.partInventory.image.tag }}"
          command: ["java", "-jar", "app.jar", "--spring.batch.job.enabled=true"]
          env:
            - name: SPRING_PROFILES_ACTIVE
              value: {{ .Values.partInventory.env.springProfilesActive | quote }}
```

| Hook annotation | When it runs |
| --------------- | ------------ |
| `pre-install` | Before any resources are created on first install |
| `post-install` | After all resources are created |
| `pre-upgrade` | Before upgrade manifests are applied |
| `post-upgrade` | After upgrade completes |
| `pre-rollback` | Before rollback manifests are applied |
| `post-rollback` | After rollback completes |
| `pre-delete` | Before uninstall |

The `hook-delete-policy: hook-succeeded` annotation cleans up the Job pod automatically after it succeeds, keeping the namespace tidy.

---

## Common Issues

| Issue | Symptom | Fix |
| ----- | ------- | --- |
| `Error: UPGRADE FAILED: another operation is in progress` | Concurrent upgrades | Previous upgrade is pending; wait or `helm rollback` to clear it |
| Release stuck in `pending-upgrade` | `helm list` shows status `pending-upgrade` | `helm rollback <release> <revision>` to force-clear the state |
| `--atomic` rolls back but CI reports success | Exit code not checked | `--atomic` exits non-zero on rollback — ensure CI fails on non-zero exit |
| Rollback doesn't fix the problem | App still broken after rollback | Issue is in persistent state (DB schema, config outside Helm) not in the chart |
| `helm get manifest` differs from `kubectl get` | Manual `kubectl apply` was run outside Helm | Helm drift — avoid kubectl edits on Helm-managed resources; use `helm upgrade` |
| Values from `--set` not visible in `helm get values` | `--set` values are stored | Run `helm get values <release> --all` — `--set` overrides appear under "USER-SUPPLIED VALUES" |
