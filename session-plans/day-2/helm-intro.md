# Helm — Charts, Values, and Templating

## The Problem Helm Solves

Deploying `part-inventory-service` to Kubernetes requires at least five separate YAML files: Deployment, Service, ConfigMap, Secret, and HPA. Deploying it to dev, staging, and prod means three nearly identical copies with minor differences (image tag, replica count, resource limits).

```text
Without Helm:
  kubectl apply -f dev/deployment.yaml
  kubectl apply -f dev/service.yaml
  kubectl apply -f dev/configmap.yaml
  # ... repeat for staging and prod with different values copy-pasted in

With Helm:
  helm install inventory ./charts/part-inventory --values values-dev.yaml
  helm install inventory ./charts/part-inventory --values values-prod.yaml
  helm upgrade inventory ./charts/part-inventory --set image.tag=v2
```

Helm is a **package manager for Kubernetes** — it bundles related manifests into a chart, adds templating so values change without copy-pasting, and tracks installed releases so you can upgrade and rollback cleanly.

---

## Core Concepts

| Term | What it is |
| ---- | ---------- |
| **Chart** | A directory of templates + metadata — the "package" |
| **Release** | A deployed instance of a chart in a cluster (`helm install` creates one) |
| **Values** | Key-value configuration injected into templates at install/upgrade time |
| **Repository** | A server hosting packaged charts (like npm registry, but for Helm) |
| **Revision** | A numbered version of a release — each `helm upgrade` increments it |

---

## Install Helm

```bash
# macOS
brew install helm

# Linux
curl https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash

# Verify
helm version
# version.BuildInfo{Version:"v3.15.0", ...}
```

Helm 3 (current) stores release state as Secrets in the cluster namespace — no Tiller pod needed.

---

## Helm Chart Structure

```text
part-inventory/           ← chart root directory
├── Chart.yaml            ← chart metadata (name, version, appVersion)
├── values.yaml           ← default values (overridden per environment)
├── templates/            ← Go-template YAML files
│   ├── deployment.yaml
│   ├── service.yaml
│   ├── configmap.yaml
│   ├── hpa.yaml
│   ├── _helpers.tpl      ← named template fragments (reusable partials)
│   └── NOTES.txt         ← printed after install (usage instructions)
└── charts/               ← sub-charts (dependencies)
```

---

## Building a Chart for part-inventory-service

### Chart.yaml

```yaml
apiVersion: v2
name: part-inventory
description: Helm chart for part-inventory-service
type: application
version: 0.1.0          # chart version — bump when the chart changes
appVersion: "1.0.0"     # application version — matches the image tag
```

### values.yaml (defaults)

```yaml
replicaCount: 2

image:
  repository: ram1uj/part-inventory-service
  tag: "latest"
  pullPolicy: IfNotPresent

service:
  type: ClusterIP
  port: 80
  targetPort: 8080

resources:
  requests:
    cpu: "250m"
    memory: "256Mi"
  limits:
    cpu: "1000m"
    memory: "512Mi"

autoscaling:
  enabled: false
  minReplicas: 2
  maxReplicas: 10
  targetCPUUtilizationPercentage: 50

env:
  springProfile: dev
  mysqlHost: localhost
  mysqlPort: "3306"
  mysqlDatabase: parts_db

mysql:
  enabled: true
  secretName: mysql-secret
```

### templates/deployment.yaml

```yaml
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {{ include "part-inventory.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "part-inventory.labels" . | nindent 4 }}
spec:
  {{- if not .Values.autoscaling.enabled }}
  replicas: {{ .Values.replicaCount }}
  {{- end }}
  selector:
    matchLabels:
      {{- include "part-inventory.selectorLabels" . | nindent 6 }}
  template:
    metadata:
      labels:
        {{- include "part-inventory.selectorLabels" . | nindent 8 }}
    spec:
      containers:
        - name: {{ .Chart.Name }}
          image: "{{ .Values.image.repository }}:{{ .Values.image.tag }}"
          imagePullPolicy: {{ .Values.image.pullPolicy }}
          ports:
            - containerPort: {{ .Values.service.targetPort }}
          env:
            - name: SPRING_PROFILES_ACTIVE
              value: {{ .Values.env.springProfile | quote }}
            - name: MYSQL_HOST
              value: {{ .Values.env.mysqlHost | quote }}
            - name: MYSQL_PORT
              value: {{ .Values.env.mysqlPort | quote }}
            - name: MYSQL_DATABASE
              value: {{ .Values.env.mysqlDatabase | quote }}
            {{- if .Values.mysql.enabled }}
            - name: MYSQL_USER
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.mysql.secretName }}
                  key: mysql-user
            - name: MYSQL_PASSWORD
              valueFrom:
                secretKeyRef:
                  name: {{ .Values.mysql.secretName }}
                  key: mysql-password
            {{- end }}
          resources:
            {{- toYaml .Values.resources | nindent 12 }}
          readinessProbe:
            httpGet:
              path: /actuator/health/readiness
              port: {{ .Values.service.targetPort }}
            initialDelaySeconds: 10
            periodSeconds: 5
```

### templates/service.yaml

```yaml
apiVersion: v1
kind: Service
metadata:
  name: {{ include "part-inventory.fullname" . }}
  namespace: {{ .Release.Namespace }}
  labels:
    {{- include "part-inventory.labels" . | nindent 4 }}
spec:
  type: {{ .Values.service.type }}
  ports:
    - port: {{ .Values.service.port }}
      targetPort: {{ .Values.service.targetPort }}
  selector:
    {{- include "part-inventory.selectorLabels" . | nindent 4 }}
```

### templates/hpa.yaml

```yaml
{{- if .Values.autoscaling.enabled }}
apiVersion: autoscaling/v2
kind: HorizontalPodAutoscaler
metadata:
  name: {{ include "part-inventory.fullname" . }}
  namespace: {{ .Release.Namespace }}
spec:
  scaleTargetRef:
    apiVersion: apps/v1
    kind: Deployment
    name: {{ include "part-inventory.fullname" . }}
  minReplicas: {{ .Values.autoscaling.minReplicas }}
  maxReplicas: {{ .Values.autoscaling.maxReplicas }}
  metrics:
    - type: Resource
      resource:
        name: cpu
        target:
          type: Utilization
          averageUtilization: {{ .Values.autoscaling.targetCPUUtilizationPercentage }}
{{- end }}
```

The `{{- if .Values.autoscaling.enabled }}` / `{{- end }}` block means the HPA manifest is only included when autoscaling is turned on.

### templates/_helpers.tpl

```gotemplate
{{/*
Expand the name of the chart.
*/}}
{{- define "part-inventory.name" -}}
{{- .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Full release name: <release>-<chart>, truncated to 63 chars.
*/}}
{{- define "part-inventory.fullname" -}}
{{- printf "%s-%s" .Release.Name .Chart.Name | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to all resources.
*/}}
{{- define "part-inventory.labels" -}}
helm.sh/chart: {{ .Chart.Name }}-{{ .Chart.Version }}
app.kubernetes.io/name: {{ include "part-inventory.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels — used in matchLabels and pod template.
*/}}
{{- define "part-inventory.selectorLabels" -}}
app.kubernetes.io/name: {{ include "part-inventory.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}
```

---

## Environment-Specific Values Files

```yaml
# values-dev.yaml
replicaCount: 1
image:
  tag: "latest"
env:
  springProfile: dev
  mysqlHost: mysql.dev.svc.cluster.local
autoscaling:
  enabled: false
mysql:
  enabled: false
```

```yaml
# values-prod.yaml
replicaCount: 3
image:
  tag: "1.4.2"
env:
  springProfile: prod
  mysqlHost: mysql.prod.svc.cluster.local
  mysqlDatabase: parts_prod
resources:
  requests:
    cpu: "500m"
    memory: "512Mi"
  limits:
    cpu: "2"
    memory: "1Gi"
autoscaling:
  enabled: true
  minReplicas: 3
  maxReplicas: 20
  targetCPUUtilizationPercentage: 60
```

Values are **merged**: `values.yaml` provides all defaults, `values-prod.yaml` overrides only what differs. Unmentioned keys keep the default.

---

## Install, Upgrade, Rollback

### Install

```bash
# Install to inventory-service namespace, using dev values
helm install inventory-dev ./part-inventory \
  --namespace inventory-service \
  --create-namespace \
  --values values-dev.yaml

# Verify
helm list -n inventory-service
# NAME            NAMESPACE           REVISION  STATUS    CHART
# inventory-dev   inventory-service   1         deployed  part-inventory-0.1.0

kubectl get pods -n inventory-service
```

### Upgrade

```bash
# Deploy a new image tag
helm upgrade inventory-dev ./part-inventory \
  --namespace inventory-service \
  --values values-dev.yaml \
  --set image.tag=v2

# Check revision history
helm history inventory-dev -n inventory-service
# REVISION  STATUS      CHART                   DESCRIPTION
# 1         superseded  part-inventory-0.1.0    Install complete
# 2         deployed    part-inventory-0.1.0    Upgrade complete
```

### Rollback

```bash
# Roll back to revision 1
helm rollback inventory-dev 1 -n inventory-service

# Confirm
helm history inventory-dev -n inventory-service
# REVISION  STATUS      DESCRIPTION
# 1         superseded  Install complete
# 2         superseded  Upgrade complete
# 3         deployed    Rollback to 1
```

Helm rollback triggers a `kubectl rollout` of the Deployment — pods are replaced rolling.

### Dry Run (Preview Before Apply)

```bash
# Render templates without applying — diff what would change
helm upgrade inventory-dev ./part-inventory \
  --namespace inventory-service \
  --values values-prod.yaml \
  --dry-run \
  --debug
```

---

## Inspect and Debug

```bash
# Show rendered manifests for an installed release
helm get manifest inventory-dev -n inventory-service

# Show the values in use (merged defaults + overrides)
helm get values inventory-dev -n inventory-service

# Show all values including defaults
helm get values inventory-dev -n inventory-service --all

# Lint the chart for errors before installing
helm lint ./part-inventory

# Render templates locally without a cluster
helm template inventory-dev ./part-inventory \
  --values values-dev.yaml \
  --namespace inventory-service
```

---

## Using Public Charts (Helm Repositories)

Rather than writing everything from scratch, use community charts:

```bash
# Add the Bitnami repository
helm repo add bitnami https://charts.bitnami.com/bitnami
helm repo update

# Search for a chart
helm search repo bitnami/mysql

# Show available configuration options
helm show values bitnami/mysql | head -60

# Install MySQL with custom values
helm install mysql bitnami/mysql \
  --namespace inventory-service \
  --set auth.rootPassword=rootpass \
  --set auth.database=parts_db \
  --set auth.username=parts_user \
  --set auth.password=parts_pass

# Use as a dependency in Chart.yaml
```

### Declaring chart dependencies

```yaml
# Chart.yaml
dependencies:
  - name: mysql
    version: "10.1.0"
    repository: https://charts.bitnami.com/bitnami
    condition: mysql.enabled    # only pull in when mysql.enabled=true
```

```bash
# Download dependencies into charts/
helm dependency update ./part-inventory

# Install chart with embedded MySQL
helm install inventory-stack ./part-inventory \
  --values values-prod.yaml \
  --set mysql.enabled=true
```

---

## Helm Templating Reference

### Common functions

```yaml
# Quote strings to handle special characters
value: {{ .Values.env.mysqlHost | quote }}

# Default value if not set
replicas: {{ .Values.replicaCount | default 1 }}

# Convert to YAML block (for nested structures)
resources:
  {{- toYaml .Values.resources | nindent 12 }}

# Conditional block
{{- if .Values.autoscaling.enabled }}
...
{{- end }}

# Loop over a list
{{- range .Values.extraEnv }}
- name: {{ .name }}
  value: {{ .value | quote }}
{{- end }}

# Trim whitespace (the - in {{- removes leading newline)
{{- include "part-inventory.labels" . | nindent 4 }}
```

### Built-in objects

| Object | Contains |
| ------ | -------- |
| `.Release.Name` | The release name (`inventory-dev`) |
| `.Release.Namespace` | The namespace |
| `.Release.Service` | Always `"Helm"` |
| `.Chart.Name` | From `Chart.yaml` name field |
| `.Chart.Version` | Chart version |
| `.Chart.AppVersion` | Application version |
| `.Values.*` | Everything from values.yaml + overrides |

---

## Lab — Package and Deploy part-inventory-service

```bash
# 1. Create the chart scaffold
helm create part-inventory
# Generates the full directory structure — then replace templates with the ones above

# 2. Lint for errors
helm lint ./part-inventory

# 3. Dry run to preview
helm template inventory-dev ./part-inventory \
  --values values-dev.yaml \
  --namespace inventory-service

# 4. Install to the cluster
helm install inventory-dev ./part-inventory \
  --namespace inventory-service \
  --create-namespace \
  --values values-dev.yaml

# 5. Verify
helm list -n inventory-service
kubectl get all -n inventory-service

# 6. Upgrade with a new image tag
helm upgrade inventory-dev ./part-inventory \
  --namespace inventory-service \
  --values values-dev.yaml \
  --set image.tag=v2

kubectl rollout status deployment -n inventory-service

# 7. Roll back
helm rollback inventory-dev 1 -n inventory-service

# 8. Uninstall
helm uninstall inventory-dev -n inventory-service
```

---

## Verification Commands

```bash
# All releases in all namespaces
helm list -A

# Release history and revision numbers
helm history <release-name> -n <namespace>

# Rendered manifests currently deployed
helm get manifest <release-name> -n <namespace>

# Effective values (merged)
helm get values <release-name> -n <namespace> --all

# Chart lint
helm lint ./part-inventory

# Repo management
helm repo list
helm repo update
helm search repo <keyword>
```

---

## Common Issues

| Issue | Symptom | Fix |
| ----- | ------- | --- |
| `Error: INSTALLATION FAILED: cannot re-use a name` | Release name already exists | Use `helm upgrade --install` (installs if not present, upgrades if present) |
| Template renders wrong value | Unexpected string in manifest | Run `helm template` locally to inspect rendered output |
| `Error: chart requires kubeVersion` | Cluster version mismatch | Check `kubeVersion` field in Chart.yaml; update or remove the constraint |
| Values not applied | Override has no effect | Value path is wrong — use `helm get values --all` to see effective tree |
| Rollback doesn't restore the old config | Only Deployment rolled back, ConfigMap unchanged | Helm rollback re-applies the full previous manifest set — check if the resource is in the chart |
| `Error: no matches for kind "HorizontalPodAutoscaler"` | Wrong API version | Check cluster version supports `autoscaling/v2`; use `v2beta2` on older clusters |
