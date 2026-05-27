# Service Accounts and Security Context

## Service Accounts

### What is a ServiceAccount?

A **ServiceAccount** is a Kubernetes identity for processes running inside Pods. While human users authenticate with certificates or tokens in a kubeconfig, Pods authenticate to the Kubernetes API using a ServiceAccount token.

Every namespace has a `default` ServiceAccount. Every Pod is automatically assigned the `default` SA unless you specify otherwise.

```bash
kubectl get serviceaccounts -n dev
kubectl describe serviceaccount dev-user -n dev
```

### Why Use a Custom ServiceAccount?

The `default` ServiceAccount has no extra permissions, but it is still an identity. Best practice: create a dedicated SA for each workload and grant it only what it needs via RBAC. This gives you:

- Auditability — API calls are attributed to a specific workload
- Least privilege — each Pod gets only the permissions it needs
- Isolation — one compromised Pod cannot escalate to others

### Creating and Using a ServiceAccount

```yaml
apiVersion: v1
kind: ServiceAccount
metadata:
  name: dev-user
  namespace: dev
```

Assign it to a Pod:

```yaml
spec:
  serviceAccountName: dev-user    # explicitly set; defaults to "default" if omitted
  containers:
    - name: app
      image: myapp:1.0
```

### Auto-mounted Token

By default, Kubernetes mounts a token for the Pod's ServiceAccount at:

```text
/var/run/secrets/kubernetes.io/serviceaccount/token
```

This token is used when the Pod's code calls the Kubernetes API (e.g., via the `client-go` SDK or `kubectl` inside the container). Disable auto-mounting if the Pod doesn't need API access:

```yaml
spec:
  automountServiceAccountToken: false   # Pod level
```

or:

```yaml
metadata:
  name: dev-user
automountServiceAccountToken: false     # ServiceAccount level — applies to all Pods using this SA
```

### Generating a Token for kubectl (Testing / CI)

```bash
# Short-lived token (expires in 1h by default)
kubectl create token dev-user -n dev

# Use the token to configure kubectl credentials
kubectl config set-credentials dev-user \
  --token=$(kubectl create token dev-user -n dev)

kubectl config set-context dev-user-context \
  --cluster=$(kubectl config view --minify -o jsonpath='{.clusters[0].name}') \
  --user=dev-user \
  --namespace=dev

kubectl config use-context dev-user-context
```

---

## Security Context

A **SecurityContext** defines privilege and access control settings for a Pod or container. It hardens workloads by restricting what the process can do inside the container.

There are two levels:

| Level | Field | Applies to |
| --- | --- | --- |
| Pod | `spec.securityContext` | All containers in the Pod |
| Container | `spec.containers[*].securityContext` | Individual container |

Container-level settings override Pod-level settings when both are set.

---

## Pod-Level SecurityContext (spec.securityContext)

```yaml
spec:
  securityContext:
    runAsUser: 1000           # UID for all containers (overrides image default)
    runAsGroup: 3000          # GID for all containers
    fsGroup: 2000             # GID applied to mounted volumes (for file ownership)
    runAsNonRoot: true        # reject containers that try to run as root (UID 0)
    seccompProfile:
      type: RuntimeDefault    # apply the container runtime's default seccomp filter
```

### fsGroup

When a volume is mounted, Kubernetes changes the ownership of that volume to `fsGroup`. Useful for shared volume access when containers run as non-root users.

---

## Container-Level SecurityContext (containers[*].securityContext)

```yaml
containers:
  - name: app
    securityContext:
      runAsUser: 1000
      runAsNonRoot: true
      readOnlyRootFilesystem: true    # container cannot write to its own filesystem
      allowPrivilegeEscalation: false # prevents sudo / setuid binaries from gaining more privs
      capabilities:
        drop: ["ALL"]                 # drop all Linux capabilities
        add: ["NET_BIND_SERVICE"]     # re-add only what is needed (e.g., bind port < 1024)
```

### Key Fields Explained

| Field | Default | Effect |
| --- | --- | --- |
| `runAsUser` | from image | UID the process runs as |
| `runAsNonRoot` | false | Rejects startup if UID == 0 |
| `readOnlyRootFilesystem` | false | Makes `/` read-only; writes must go to mounted volumes |
| `allowPrivilegeEscalation` | true | If false, child processes cannot gain more privs than parent |
| `privileged` | false | If true, container gets full host access (avoid unless absolutely necessary) |
| `capabilities.drop` | — | Remove Linux capabilities (drop `ALL` as baseline) |
| `capabilities.add` | — | Re-add specific capabilities after dropping |

### Linux Capabilities (common ones)

| Capability | What it allows |
| --- | --- |
| `NET_BIND_SERVICE` | Bind to ports below 1024 |
| `NET_ADMIN` | Configure network interfaces |
| `SYS_PTRACE` | Trace/debug other processes |
| `SYS_ADMIN` | Broad system administration (almost as powerful as root) |
| `CHOWN` | Change file ownership |

Drop `ALL` and add back only what the app genuinely needs.

---

## Full Example: Pod with ServiceAccount + Security Context

```yaml
apiVersion: v1
kind: Pod
metadata:
  name: secure-app
  namespace: dev
spec:
  serviceAccountName: dev-user       # custom SA with scoped RBAC permissions
  automountServiceAccountToken: false  # app doesn't call Kubernetes API

  securityContext:                   # Pod-level
    runAsUser: 1000
    runAsGroup: 3000
    fsGroup: 2000
    runAsNonRoot: true

  containers:
    - name: app
      image: ram1uj/part-inventory-service
      securityContext:               # Container-level
        readOnlyRootFilesystem: true
        allowPrivilegeEscalation: false
        capabilities:
          drop: ["ALL"]
      ports:
        - containerPort: 8080
      volumeMounts:
        - name: tmp-dir
          mountPath: /tmp            # writable scratch space for read-only root FS

  volumes:
    - name: tmp-dir
      emptyDir: {}
```

> **Note:** `readOnlyRootFilesystem: true` means the app cannot write anywhere except explicitly mounted volumes. Spring Boot writes temp files to `/tmp`, so always mount an `emptyDir` at `/tmp` when using this setting.

---

## ServiceAccount + RBAC + Security Context: The Full Picture

```
ServiceAccount  →  Identity (who the Pod is)
RBAC Role       →  Permissions (what the Pod can do in Kubernetes)
SecurityContext →  Isolation (what the process can do on the OS)
```

These three work together. A hardened workload:
1. Has a **dedicated ServiceAccount** (not `default`)
2. Has a **Role** with only the verbs/resources it actually needs
3. Runs with **`runAsNonRoot`**, **`readOnlyRootFilesystem`**, **`allowPrivilegeEscalation: false`**, and capabilities dropped

---

## Key Takeaways

- Never use the `default` ServiceAccount for workloads that call the Kubernetes API
- Disable `automountServiceAccountToken` for Pods that don't need API access
- `runAsNonRoot: true` + `readOnlyRootFilesystem: true` + `allowPrivilegeEscalation: false` is a strong baseline for any container
- Drop `ALL` capabilities and add back only what the app needs
- `fsGroup` is essential when a non-root container needs to write to a mounted volume
