# Kubernetes Custom Resource Definitions (CRDs)
## Step-by-Step Learning Guide

---


## Step 1: Prerequisites & Environment Setup

Before writing your first CRD, you need a local Kubernetes cluster and the right tools.

### Required Tools

| Tool | Purpose |
|------|---------|
| `kind` or `minikube` | Local Kubernetes cluster |
| `kubectl` | CLI for interacting with Kubernetes |
| `Go` (optional) | Required for building controllers with kubebuilder |
| `k9s` (optional) | Terminal UI — shows CRDs and instances in real time |

### Install kind and Create a Cluster

```bash
# Install kind (macOS)
brew install kind

# Create a cluster named crd-lab
kind create cluster --name crd-lab

# Verify cluster is running
kubectl cluster-info --context kind-crd-lab

# Output:
# Kubernetes control plane is running at https://127.0.0.1:57893
```

> **Tip:** Use `k9s` as a visual terminal UI — it shows your CRDs and their instances in real time while you develop.

---

## Step 2: Understanding CRD Architecture

A CRD is a schema registered with the Kubernetes API server. Once registered, you create **Custom Resources (CRs)** — instances of that schema — just like you'd create a Pod or Deployment.

### Architecture Flow

```
CRD (CustomResourceDefinition)   ← The schema / blueprint
          ↓ registered with
Kubernetes API Server            ← Stores, validates, serves resources
          ↓ user creates
Custom Resource (CR)             ← An instance, e.g. my-database
          ↓ watched by
Controller / Operator            ← Reacts and reconciles desired state
          ↓ manages
Native Resources                 ← Pod, Service, PVC, etc.
```

### Key Terminology

| Term | What It Is | Analogy |
|------|-----------|---------|
| `CRD` | The schema definition registered in the cluster | Class definition in OOP |
| `CR` | An instance of a CRD (what users create) | Object instance |
| `group` | API group like `apps.example.com` | Namespace / package |
| `version` | `v1`, `v1beta1` — schema versioning | API version |
| `kind` | The resource type name e.g. `Database` | Class name |
| `spec` | Desired state declared by the user | Input / config |
| `status` | Current state written by the controller | Output / observed state |
| `Controller` | Reconciliation loop that acts on CRs | Event handler |
| `Operator` | Controller packaged with domain logic | Expert system |

---

## Step 3: Writing Your First CRD

We'll create a `Database` CRD — a resource that represents a managed database instance.

### 1. Define the CRD Schema

```yaml
# database-crd.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: databases.storage.example.com   # must be: plural.group
spec:
  group: storage.example.com
  scope: Namespaced                      # or Cluster
  names:
    plural: databases
    singular: database
    kind: Database
    shortNames:
      - db                               # kubectl get db works!
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
              required: [engine, storage]
              properties:
                engine:
                  type: string
                  enum: [postgres, mysql, redis]
                version:
                  type: string
                replicas:
                  type: integer
                  minimum: 1
                  maximum: 5
                  default: 1
                storage:
                  type: string
                  pattern: '^[0-9]+(Gi|Mi)$'   # e.g. 10Gi
                backup:
                  type: object
                  properties:
                    enabled:
                      type: boolean
                      default: false
                    schedule:
                      type: string              # cron expression
            status:
              type: object
              properties:
                phase:
                  type: string                  # Pending / Running / Failed
                readyReplicas:
                  type: integer
                connectionString:
                  type: string
      additionalPrinterColumns:                 # shown in kubectl get
        - name: Engine
          type: string
          jsonPath: .spec.engine
        - name: Replicas
          type: integer
          jsonPath: .spec.replicas
        - name: Phase
          type: string
          jsonPath: .status.phase
        - name: Age
          type: date
          jsonPath: .metadata.creationTimestamp
```

### 2. Apply the CRD to Your Cluster

```bash
kubectl apply -f database-crd.yaml
# customresourcedefinition.apiextensions.k8s.io/databases.storage.example.com created

# Verify it was registered
kubectl get crd databases.storage.example.com
# NAME                              CREATED AT
# databases.storage.example.com    2024-01-15T10:00:00Z
```

### 3. Create a Custom Resource (an Instance)

```yaml
# my-database.yaml
apiVersion: storage.example.com/v1
kind: Database
metadata:
  name: production-db
  namespace: default
spec:
  engine: postgres
  version: "15.2"
  replicas: 3
  storage: 50Gi
  backup:
    enabled: true
    schedule: "0 2 * * *"
```

```bash
kubectl apply -f my-database.yaml
# database.storage.example.com/production-db created

# Use the short name!
kubectl get db
# NAME            ENGINE     REPLICAS   PHASE   AGE
# production-db   postgres   3                  5s

kubectl describe db production-db
```

> **Note:** The Phase column is empty because there's no controller yet. The CRD stores state — a controller acts on it.

---

## Step 4: Schema Validation & Defaulting

OpenAPI v3 schema validation is enforced at admission time — bad YAML is rejected before it even hits etcd.

### Try Submitting an Invalid Resource

```yaml
# invalid example
spec:
  engine: oracle    # ❌ not in enum: [postgres, mysql, redis]
  replicas: 10      # ❌ maximum is 5
  storage: "big"    # ❌ doesn't match pattern '^[0-9]+(Gi|Mi)$'
```

```bash
kubectl apply -f invalid-db.yaml
# The Database "bad-db" is invalid:
#   spec.engine: Unsupported value: "oracle": supported values: "postgres","mysql","redis"
#   spec.replicas: Invalid value: 10: must be less than or equal to 5
#   spec.storage: Invalid value: "big": must match pattern '^[0-9]+(Gi|Mi)$'
```

### Validation Features Reference

| Feature | YAML Keyword | Example |
|---------|-------------|---------|
| Allowed values | `enum` | `enum: [postgres, mysql]` |
| Required fields | `required` | `required: [engine, storage]` |
| Number range | `minimum / maximum` | `minimum: 1, maximum: 5` |
| String pattern | `pattern` | `pattern: '^[0-9]+(Gi|Mi)$'` |
| String length | `minLength / maxLength` | `maxLength: 63` |
| Default values | `default` | `default: 1` |
| Nullable | `nullable: true` | field can be null |
| Format hints | `format` | `format: date-time` |

> **Warning:** Use `x-kubernetes-preserve-unknown-fields: true` sparingly — it bypasses validation for a subtree and should only be used for truly dynamic content like raw JSON.

---

## Step 5: Building a Simple Controller

A controller watches for changes to your CRs and reconciles — creating or updating Kubernetes resources to match the desired state.

### Reconciliation Loop

```
User creates/updates/deletes a CR
          ↓
Informer/Watch detects change → enqueues to work queue
          ↓
Worker dequeues → calls Reconcile()
          ↓
Reconcile: compare desired vs actual → create/update/delete child resources
          ↓
Update CR .status with current state
```

### Shell-Based Controller (Learning Example)

Before writing Go, understand the concept with a simple bash controller:

```bash
#!/bin/bash
# simple-controller.sh
# A simple watch-and-reconcile loop in bash (for learning only)

while true; do
  # Get all Database CRs
  DATABASES=$(kubectl get database -o json | jq -r '.items[].metadata.name')

  for DB in $DATABASES; do
    ENGINE=$(kubectl get database $DB -o jsonpath='{.spec.engine}')
    REPLICAS=$(kubectl get database $DB -o jsonpath='{.spec.replicas}')

    # Check if StatefulSet already exists
    if ! kubectl get statefulset "$DB-$ENGINE" &>/dev/null; then
      echo "Creating StatefulSet for $DB ($ENGINE)"
      kubectl create statefulset "$DB-$ENGINE" \
        --image="$ENGINE:latest" \
        --replicas=$REPLICAS

      # Update status
      kubectl patch database $DB \
        --type=merge \
        --subresource=status \
        -p "{\"status\":{\"phase\":\"Running\",\"readyReplicas\":$REPLICAS}}"
    fi
  done

  sleep 10
done
```

### Production Controller with Go + controller-runtime

```go
// internal/controller/database_controller.go
package controller

import (
    "context"
    storagev1 "github.com/example/db-operator/api/v1"
    appsv1 "k8s.io/api/apps/v1"
    "sigs.k8s.io/controller-runtime/pkg/client"
    "sigs.k8s.io/controller-runtime/pkg/reconcile"
)

type DatabaseReconciler struct {
    client.Client
}

// Reconcile is called every time a Database CR changes
func (r *DatabaseReconciler) Reconcile(
    ctx context.Context,
    req reconcile.Request,
) (reconcile.Result, error) {

    // 1. Fetch the Database CR
    db := &storagev1.Database{}
    if err := r.Get(ctx, req.NamespacedName, db); err != nil {
        return reconcile.Result{}, client.IgnoreNotFound(err)
    }

    // 2. Check if StatefulSet exists
    sts := &appsv1.StatefulSet{}
    err := r.Get(ctx, req.NamespacedName, sts)

    if err != nil {
        // 3. Create the StatefulSet
        newSts := buildStatefulSet(db)
        if err := r.Create(ctx, newSts); err != nil {
            return reconcile.Result{}, err
        }
    }

    // 4. Update status
    db.Status.Phase = "Running"
    db.Status.ReadyReplicas = *db.Spec.Replicas
    r.Status().Update(ctx, db)

    return reconcile.Result{}, nil
}
```

---

## Step 6: Building with Kubebuilder (Operator Framework)

Kubebuilder scaffolds a complete operator project — CRDs, controllers, RBAC, and Webhooks — from a single CLI.

### Scaffold a New Operator Project

```bash
# Install kubebuilder
curl -L -o kubebuilder "https://go.kubebuilder.io/dl/latest/$(go env GOOS)/$(go env GOARCH)"
chmod +x kubebuilder && mv kubebuilder /usr/local/bin/

# Initialize new operator project
mkdir db-operator && cd db-operator
kubebuilder init --domain example.com --repo github.com/example/db-operator

# Create API (CRD + Controller)
kubebuilder create api \
  --group storage \
  --version v1 \
  --kind Database
# ? Create Resource [y/n] y
# ? Create Controller [y/n] y

# Generated project structure:
# db-operator/
# ├── api/v1/
# │   ├── database_types.go       ← Define your spec/status here
# │   └── zz_generated.deepcopy.go
# ├── internal/controller/
# │   └── database_controller.go  ← Your reconcile logic
# ├── config/
# │   ├── crd/                    ← Auto-generated CRD YAML
# │   ├── rbac/                   ← Auto-generated RBAC
# │   └── manager/                ← Operator deployment
# └── Makefile
```

### Define Types in Go

```go
// api/v1/database_types.go

// +kubebuilder:object:root=true
// +kubebuilder:subresource:status
// +kubebuilder:printcolumn:name="Engine",type=string,JSONPath=`.spec.engine`
// +kubebuilder:printcolumn:name="Phase",type=string,JSONPath=`.status.phase`

type DatabaseSpec struct {
    // +kubebuilder:validation:Enum=postgres;mysql;redis
    Engine string `json:"engine"`

    // +kubebuilder:validation:Minimum=1
    // +kubebuilder:validation:Maximum=5
    // +kubebuilder:default=1
    Replicas *int32 `json:"replicas,omitempty"`

    Storage string `json:"storage"`
}

type DatabaseStatus struct {
    Phase            string `json:"phase,omitempty"`
    ReadyReplicas    int32  `json:"readyReplicas,omitempty"`
    ConnectionString string `json:"connectionString,omitempty"`
}

// Generate CRD YAML from these Go types:
// $ make generate && make manifests
```

### Build and Deploy

```bash
# Generate CRD YAML from Go annotations
make generate manifests

# Install CRDs into cluster
make install

# Run operator locally (outside cluster)
make run

# Or deploy operator as a pod inside cluster
make docker-build docker-push IMG=myregistry/db-operator:v0.1
make deploy IMG=myregistry/db-operator:v0.1
```

---

## Step 7: RBAC for CRDs

CRDs are first-class Kubernetes citizens — you can control who can create, get, list, update, or delete them using standard RBAC.

### Allow Developers to Create/Read Databases

```yaml
# rbac-developer.yaml
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: database-developer
rules:
  - apiGroups: ["storage.example.com"]
    resources: ["databases"]
    verbs: ["get", "list", "watch", "create"]
    # Developers can read+create but NOT delete or update
---
apiVersion: rbac.authorization.k8s.io/v1
kind: ClusterRole
metadata:
  name: database-admin
rules:
  - apiGroups: ["storage.example.com"]
    resources: ["databases", "databases/status"]
    verbs: ["*"]
    # Full access including status subresource
```

### Enable Status Subresource

Define `subresources: status: {}` in your CRD so only controllers (not users) can update `.status`. This prevents developers from manually faking status fields.

```yaml
versions:
  - name: v1
    served: true
    storage: true
    subresources:
      status: {}      # enables /status endpoint
      scale:          # optional: enables kubectl scale
        specReplicasPath: .spec.replicas
        statusReplicasPath: .status.readyReplicas
```

---

## Step 8: CRD Versioning & Conversion

As your CRD evolves you'll need to add fields or change structure without breaking existing resources.

### Serving Multiple Versions Simultaneously

```yaml
versions:
  - name: v1
    served: true        # v1 is still accessible
    storage: false      # but NOT the stored version

  - name: v2
    served: true
    storage: true       # v2 is now the stored version
    schema:
      openAPIV3Schema:
        properties:
          spec:
            properties:
              # New in v2: renamed 'storage' to 'diskSize'
              diskSize:
                type: string

conversion:
  strategy: Webhook     # Use a webhook to convert between v1 ↔ v2
  webhook:
    conversionReviewVersions: ["v1"]
    clientConfig:
      service:
        name: db-operator-webhook
        namespace: db-system
        path: /convert
```

### Conversion Strategy Comparison

| Strategy | Use When | Effort |
|----------|---------|--------|
| `None` | Only one version ever, no migration needed | Zero |
| `NoneConversion` | Additive-only changes (new optional fields) | Low |
| `Webhook` | Renames, restructures, type changes | Medium–High |

---

## Step 9: End-to-End WebApp CRD

A complete real-world example: a `WebApp` CRD that provisions a Deployment + Service + HorizontalPodAutoscaler from a single resource definition.

### The CRD Schema

```yaml
# webapp-crd.yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: webapps.apps.example.com
spec:
  group: apps.example.com
  scope: Namespaced
  names:
    plural: webapps
    singular: webapp
    kind: WebApp
    shortNames: [wa]
  versions:
    - name: v1
      served: true
      storage: true
      subresources:
        status: {}
      schema:
        openAPIV3Schema:
          type: object
          properties:
            spec:
              type: object
              required: [image, port]
              properties:
                image:     { type: string }
                port:      { type: integer }
                replicas:  { type: integer, default: 2 }
                autoscale:
                  type: object
                  properties:
                    enabled:     { type: boolean, default: false }
                    minReplicas: { type: integer, default: 2 }
                    maxReplicas: { type: integer, default: 10 }
                    cpuTarget:   { type: integer, default: 70 }
                env:
                  type: array
                  items:
                    type: object
                    properties:
                      name:  { type: string }
                      value: { type: string }
            status:
              type: object
              properties:
                phase:             { type: string }
                availableReplicas: { type: integer }
                url:               { type: string }
```

### User-Facing CR — This Is All a Developer Needs to Write

```yaml
# my-webapp.yaml
apiVersion: apps.example.com/v1
kind: WebApp
metadata:
  name: frontend
spec:
  image: myrepo/frontend:v1.4.2
  port: 3000
  replicas: 3
  autoscale:
    enabled: true
    minReplicas: 2
    maxReplicas: 20
    cpuTarget: 60
  env:
    - name: API_URL
      value: https://api.example.com
```

### What the Controller Creates Automatically

```bash
kubectl apply -f my-webapp.yaml
# webapp.apps.example.com/frontend created

# Controller auto-creates these:
kubectl get all -l app=frontend
# NAME                              READY
# deployment.apps/frontend          3/3
# service/frontend                  ClusterIP   10.96.0.5
# horizontalpodautoscaler/frontend  3/20  60%  60%

kubectl get wa frontend
# NAME       PHASE     REPLICAS   URL
# frontend   Running   3          https://frontend.example.com
```

> **The Payoff:** A developer writes 15 lines of YAML. The operator creates and manages a Deployment, Service, and HPA — and continues reconciling if anything drifts or breaks.

---

## kubectl CRD Cheatsheet

```bash
# List all CRDs in cluster
kubectl get crds

# Describe a CRD (see schema)
kubectl describe crd databases.storage.example.com

# Get all instances across all namespaces
kubectl get databases -A

# Get with custom columns
kubectl get db -o wide

# Watch for changes
kubectl get db -w

# Check events for a CR
kubectl describe db production-db

# Delete a CRD (also deletes ALL instances!)
kubectl delete crd databases.storage.example.com

# Patch status manually (for testing)
kubectl patch database production-db \
  --type=merge --subresource=status \
  -p '{"status":{"phase":"Running"}}'

# Export a CR as YAML
kubectl get db production-db -o yaml

# Check if a resource type exists
kubectl api-resources | grep databases
```

---

