# Role-Based Access Control (RBAC)

## What is RBAC?

RBAC (Role-Based Access Control) is Kubernetes' authorization mechanism. It controls **who** can do **what** to **which resources**. Every API request is checked against RBAC rules before being allowed or denied.

RBAC is enforced by the Kubernetes API server and applies to:

- Human users (via kubeconfig credentials)
- Service Accounts (Pods and in-cluster workloads)
- External systems calling the API

---

## Core Components

### 1. Role and ClusterRole — the "what"

Define a set of allowed actions on resources. Permissions are **additive** — there is no "deny" rule.

| | Role | ClusterRole |
| --- | --- | --- |
| **Scope** | Single namespace | All namespaces + cluster-level resources |
| **Resources** | Namespaced (pods, services, etc.) | Namespaced + non-namespaced (nodes, PVs, namespaces) |
| **Bound with** | RoleBinding | ClusterRoleBinding *or* RoleBinding (scopes it to one namespace) |

### 2. RoleBinding and ClusterRoleBinding — the "who gets it"

Bind a Role/ClusterRole to one or more **subjects** (users, groups, or service accounts).

| | RoleBinding | ClusterRoleBinding |
| --- | --- | --- |
| **Scope** | Namespace | Cluster-wide |
| **Can bind** | Role or ClusterRole | ClusterRole only |

> **Tip:** A ClusterRole + RoleBinding is a common pattern — define the role once cluster-wide, then grant it namespace-by-namespace without duplicating Role objects.

### 3. Subjects — the "who"

```yaml
subjects:
  - kind: User                    # human user authenticated by kubeconfig
    name: alice
    apiGroup: rbac.authorization.k8s.io

  - kind: Group                   # group of users
    name: developers
    apiGroup: rbac.authorization.k8s.io

  - kind: ServiceAccount          # in-cluster workload identity
    name: dev-user
    namespace: dev
```

---

## Rules: apiGroups, Resources, Verbs

Every rule has three parts:

```yaml
rules:
  - apiGroups: [""]               # "" = core API group (pods, services, configmaps...)
    resources: ["pods"]
    verbs: ["get", "list", "watch"]

  - apiGroups: ["apps"]           # apps group (deployments, statefulsets, replicasets)
    resources: ["deployments"]
    verbs: ["get", "list", "create", "update", "delete"]
```

### Common apiGroups

| apiGroup | Resources |
| --- | --- |
| `""` (core) | pods, services, configmaps, secrets, namespaces, nodes, PVs, PVCs |
| `apps` | deployments, statefulsets, daemonsets, replicasets |
| `batch` | jobs, cronjobs |
| `rbac.authorization.k8s.io` | roles, rolebindings, clusterroles |
| `networking.k8s.io` | ingresses, networkpolicies |
| `storage.k8s.io` | storageclasses |

### Common verbs

| Verb | HTTP method | Effect |
| --- | --- | --- |
| `get` | GET (single) | Read one resource |
| `list` | GET (collection) | Read all resources of a type |
| `watch` | GET + watch | Stream changes |
| `create` | POST | Create a resource |
| `update` | PUT | Replace a resource |
| `patch` | PATCH | Partially update |
| `delete` | DELETE | Delete a resource |
| `deletecollection` | DELETE (bulk) | Delete all resources |
| `*` | all | Wildcard — all verbs |

---

## RBAC Objects in Practice

### Role (namespace-scoped)

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata:
  name: dev-role
  namespace: dev
rules:
  - apiGroups: [""]
    resources: ["pods", "services", "configmaps", "secrets"]
    verbs: ["get", "list", "watch", "create", "update", "delete"]
  - apiGroups: ["apps"]
    resources: ["deployments"]
    verbs: ["get", "list", "watch", "create", "update", "delete"]
```

### ClusterRole (cluster-scoped, read-only example)

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: cluster-viewer
rules:
  - apiGroups: ["", "apps", "batch"]
    resources: ["pods", "deployments", "services", "nodes", "namespaces"]
    verbs: ["get", "list", "watch"]
```

### RoleBinding (binds a Role to a ServiceAccount)

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata:
  name: dev-role-binding
  namespace: dev
subjects:
  - kind: ServiceAccount
    name: dev-user
    namespace: dev
roleRef:
  kind: Role
  name: dev-role
  apiGroup: rbac.authorization.k8s.io
```

### ClusterRoleBinding (binds a ClusterRole cluster-wide)

```yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRoleBinding
metadata:
  name: cluster-viewer-binding
subjects:
  - kind: ServiceAccount
    name: monitoring-sa
    namespace: monitoring
roleRef:
  kind: ClusterRole
  name: cluster-viewer
  apiGroup: rbac.authorization.k8s.io
```

---

## Default Built-in ClusterRoles

| ClusterRole | Access level |
| --- | --- |
| `cluster-admin` | Full control over all resources in the cluster |
| `admin` | Read/write most namespaced resources; can manage roles within namespace |
| `edit` | Create/update/delete most namespaced resources; cannot manage roles |
| `view` | Read-only on most namespaced resources |

Assign these with a RoleBinding to limit scope to one namespace:

```bash
# Give alice the "edit" ClusterRole but only in the "dev" namespace
kubectl create rolebinding alice-edit \
  --clusterrole=edit \
  --user=alice \
  --namespace=dev
```

---

## Testing RBAC with kubectl auth can-i

```bash
# Can the current user delete pods in the default namespace?
kubectl auth can-i delete pods

# Can service account dev-user in namespace dev list deployments?
kubectl auth can-i list deployments \
  --as=system:serviceaccount:dev:dev-user \
  --namespace=dev

# List all permissions for a service account
kubectl auth can-i --list \
  --as=system:serviceaccount:dev:dev-user \
  --namespace=dev
```

---

## RBAC for Service Accounts (In-cluster Workloads)

Every Pod runs as a ServiceAccount. If the Pod needs to call the Kubernetes API (e.g., a custom controller, monitoring agent, CI runner), grant it only the permissions it needs via RBAC.

```bash
# Typical flow
kubectl apply -f namespace.yml           # create namespace
kubectl apply -f service-account.yml     # create ServiceAccount
kubectl apply -f dev-role.yml            # create Role
kubectl apply -f rolebinding.yml         # bind Role to ServiceAccount
kubectl create token dev-user -n dev     # generate a short-lived token
```

---

## Principle of Least Privilege

- Never use `cluster-admin` for application workloads
- Prefer Role over ClusterRole unless cross-namespace or cluster-level access is required
- Grant read-only (`get`, `list`, `watch`) by default; add write verbs only when necessary
- Audit with `kubectl auth can-i --list` to review what a subject can actually do
- Avoid `verbs: ["*"]` and `resources: ["*"]` in production
