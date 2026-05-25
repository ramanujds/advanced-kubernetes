# Alerts, Dashboards, and Health Checks for Kubernetes Workloads

## What's Already Running

Follow [configure-prometheus-grafana.md](configure-prometheus-grafana.md) to install the stack. Once done:

```bash
# Verify all components are up
kubectl get pods | grep -E "prometheus|grafana|loki"
# prometheus-server-xxxx            2/2   Running
# prometheus-alertmanager-xxxx      2/2   Running
# grafana-xxxx                      1/1   Running
# loki-xxxx                         1/1   Running

# Prometheus endpoint
minikube service prometheus-server-ext --url

# Grafana endpoint (admin / admin123)
minikube service grafana-ext --url
```

---

## The Four Golden Signals

Every service should be monitored through four signals. Prometheus collects all of them automatically from the Kubernetes cluster and from the Spring Boot actuator endpoint.

| Signal | What it measures | Prometheus metric |
| ------ | ---------------- | ----------------- |
| **Latency** | How long requests take | `http_server_requests_seconds` |
| **Traffic** | How many requests per second | `http_server_requests_seconds_count` |
| **Errors** | Rate of failed requests | `http_server_requests_seconds_count{status=~"5.."}` |
| **Saturation** | How full the resource is | `container_cpu_usage_seconds_total`, `container_memory_working_set_bytes` |

---

## Enabling Spring Boot Metrics

The `part-inventory-service` and `part-order-service` expose Prometheus metrics via Spring Boot Actuator. Confirm the dependency and config are in place.

### Required dependency (already in the services)

```xml
<!-- pom.xml -->
<dependency>
    <groupId>io.micrometer</groupId>
    <artifactId>micrometer-registry-prometheus</artifactId>
</dependency>
```

### Actuator configuration

```yaml
# application.yml
management:
  endpoints:
    web:
      exposure:
        include: health,info,prometheus,metrics
  metrics:
    tags:
      application: ${spring.application.name}   # adds app label to every metric
```

### Verify metrics are exposed

```bash
kubectl port-forward svc/part-inventory-service 8080:80 -n inventory-service &
curl http://localhost:8080/actuator/prometheus | grep http_server_requests | head -10
# http_server_requests_seconds_count{application="part-inventory-service",
#   exception="None",method="GET",outcome="SUCCESS",status="200",uri="/api/parts"} 42.0
```

---

## Scraping Spring Boot Services with Prometheus

Prometheus discovers pods to scrape via annotations. Add these to each Deployment's pod template:

```yaml
# In the Deployment template.metadata.annotations
annotations:
  prometheus.io/scrape: "true"
  prometheus.io/path: "/actuator/prometheus"
  prometheus.io/port: "8080"
```

The default `prometheus-community/prometheus` chart includes a job that scrapes all pods with `prometheus.io/scrape: "true"`.

```bash
# Confirm Prometheus is scraping both services
# Open Prometheus UI → Status → Targets
minikube service prometheus-server-ext --url
# Navigate to /targets — look for part-inventory-service and part-order-service
```

---

## Key PromQL Queries

Open Prometheus UI → Graph tab to run these interactively, or paste them into Grafana panels.

### Request rate (traffic)

```promql
# Requests per second for part-inventory-service (5-min rate)
rate(http_server_requests_seconds_count{application="part-inventory-service"}[5m])

# Total RPS across all services
sum by (application) (
  rate(http_server_requests_seconds_count[5m])
)
```

### Error rate

```promql
# HTTP 5xx error rate for part-order-service
rate(http_server_requests_seconds_count{
  application="part-order-service",
  status=~"5.."
}[5m])

# Error percentage (5xx / total)
sum(rate(http_server_requests_seconds_count{status=~"5.."}[5m]))
/
sum(rate(http_server_requests_seconds_count[5m]))
* 100
```

### Latency (p95 and p99)

```promql
# 95th percentile response time for GET /api/parts
histogram_quantile(0.95,
  rate(http_server_requests_seconds_bucket{
    application="part-inventory-service",
    method="GET"
  }[5m])
)

# p99 across all endpoints
histogram_quantile(0.99,
  sum by (le, application) (
    rate(http_server_requests_seconds_bucket[5m])
  )
)
```

### Pod CPU and memory

```promql
# CPU usage per pod (cores)
sum by (pod) (
  rate(container_cpu_usage_seconds_total{
    namespace="inventory-service",
    container!=""
  }[5m])
)

# Memory usage per pod (bytes)
container_memory_working_set_bytes{
  namespace="inventory-service",
  container!=""
}

# Memory usage as % of limit
container_memory_working_set_bytes{namespace="inventory-service"}
/
container_spec_memory_limit_bytes{namespace="inventory-service"}
* 100
```

### Pod availability

```promql
# Number of ready pods per deployment
sum by (deployment) (
  kube_deployment_status_replicas_ready
)

# Pods not ready
kube_pod_status_ready{condition="false", namespace="inventory-service"}
```

---

## Grafana Dashboards

### Dashboard 1 — Kubernetes Cluster Overview (import ID 15661)

Already referenced in the setup guide. Shows node CPU/memory, pod count, namespace resource consumption.

```bash
# Import from Grafana UI
# Dashboards → Import → Enter ID: 15661 → Select Prometheus datasource → Import
```

### Dashboard 2 — Spring Boot Services Dashboard

A custom dashboard for the parts application is included as [spring-boot-services-dashboard.json](spring-boot-services-dashboard.json).

```bash
# Import the custom dashboard
# Dashboards → Import → Upload JSON file → spring-boot-services-dashboard.json
```

It shows per-service: RPS, error rate, p95 latency, pod count, JVM heap usage.

### Dashboard 3 — Kubernetes Workloads (import ID 15760)

Drill-down per namespace — CPU/memory per pod, network I/O, restarts.

```bash
# Import ID: 15760
```

### Dashboard 4 — Log Explorer (Loki)

```bash
# Grafana → Explore → Select Loki datasource

# All logs from inventory service
{app="part-inventory-service"}

# Errors only
{app="part-inventory-service"} |= "ERROR"

# Order placements
{app="part-order-service"} |= "place-order"

# Slow requests (latency > 1000ms logged by Spring Boot)
{app="part-inventory-service"} | json | duration > 1s
```

---

## Prometheus Alerting Rules

PrometheusRule resources define alerting conditions. Apply them to the same namespace as Prometheus.

### Alert file: `kubernetes-manifests/prometheus-rules.yaml`

```yaml
apiVersion: monitoring.coreos.com/v1
kind: PrometheusRule
metadata:
  name: parts-app-alerts
  namespace: default
  labels:
    app: prometheus
spec:
  groups:
    - name: parts-app
      interval: 30s
      rules:

        # Pod not ready for more than 2 minutes
        - alert: PodNotReady
          expr: |
            kube_pod_status_ready{condition="false", namespace=~"inventory-service|order-service"}
            > 0
          for: 2m
          labels:
            severity: warning
          annotations:
            summary: "Pod {{ $labels.pod }} is not ready"
            description: "Pod {{ $labels.pod }} in namespace {{ $labels.namespace }} has been not ready for 2 minutes."

        # Deployment has fewer ready replicas than desired
        - alert: DeploymentReplicasMismatch
          expr: |
            kube_deployment_status_replicas_ready
              != kube_deployment_spec_replicas
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Deployment {{ $labels.deployment }} has replica mismatch"
            description: "{{ $labels.deployment }} has {{ $value }} ready replicas but {{ $labels.spec_replicas }} desired."

        # High error rate — more than 1% of requests are 5xx
        - alert: HighErrorRate
          expr: |
            sum by (application) (
              rate(http_server_requests_seconds_count{status=~"5.."}[5m])
            )
            /
            sum by (application) (
              rate(http_server_requests_seconds_count[5m])
            )
            > 0.01
          for: 2m
          labels:
            severity: critical
          annotations:
            summary: "High error rate on {{ $labels.application }}"
            description: "{{ $labels.application }} has {{ $value | humanizePercentage }} error rate."

        # p95 latency above 1 second
        - alert: HighLatency
          expr: |
            histogram_quantile(0.95,
              sum by (le, application) (
                rate(http_server_requests_seconds_bucket[5m])
              )
            ) > 1.0
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "High p95 latency on {{ $labels.application }}"
            description: "p95 latency is {{ $value }}s on {{ $labels.application }}."

        # Pod OOMKilled
        - alert: PodOOMKilled
          expr: |
            kube_pod_container_status_last_terminated_reason{reason="OOMKilled"}
            == 1
          for: 0m
          labels:
            severity: critical
          annotations:
            summary: "Pod {{ $labels.pod }} OOMKilled"
            description: "Container {{ $labels.container }} in pod {{ $labels.pod }} was OOMKilled. Increase memory limits."

        # Container restarting repeatedly
        - alert: ContainerFrequentRestarts
          expr: |
            increase(kube_pod_container_status_restarts_total[15m]) > 3
          for: 0m
          labels:
            severity: warning
          annotations:
            summary: "Container {{ $labels.container }} restarting frequently"
            description: "{{ $labels.container }} in {{ $labels.pod }} restarted {{ $value }} times in the last 15 minutes."

        # Node CPU above 85%
        - alert: NodeHighCPU
          expr: |
            (1 - avg by (node) (
              rate(node_cpu_seconds_total{mode="idle"}[5m])
            )) > 0.85
          for: 5m
          labels:
            severity: warning
          annotations:
            summary: "Node {{ $labels.node }} CPU above 85%"
            description: "Node {{ $labels.node }} CPU utilisation is {{ $value | humanizePercentage }}."

        # Node memory above 90%
        - alert: NodeHighMemory
          expr: |
            (1 - (
              node_memory_MemAvailable_bytes /
              node_memory_MemTotal_bytes
            )) > 0.90
          for: 5m
          labels:
            severity: critical
          annotations:
            summary: "Node {{ $labels.instance }} memory above 90%"
            description: "Node {{ $labels.instance }} memory usage is {{ $value | humanizePercentage }}."
```

```bash
kubectl apply -f kubernetes-manifests/prometheus-rules.yaml

# Note: PrometheusRule CRD is part of kube-prometheus-stack.
# With standalone prometheus-community/prometheus, define rules directly
# in the prometheus-server ConfigMap under rules:
kubectl get configmap prometheus-server -o yaml | grep -A5 "rules:"
```

### Defining rules with standalone Prometheus

If using the bare `prometheus-community/prometheus` chart (not kube-prometheus-stack), add rules via Helm values:

```yaml
# prometheus-rules-values.yaml
serverFiles:
  alerting_rules.yml:
    groups:
      - name: parts-app
        rules:
          - alert: PodNotReady
            expr: kube_pod_status_ready{condition="false"} > 0
            for: 2m
            labels:
              severity: warning
            annotations:
              summary: "Pod {{ $labels.pod }} not ready"
```

```bash
helm upgrade prometheus prometheus-community/prometheus \
  -f prometheus-rules-values.yaml
```

---

## Alertmanager: Route Alerts to Slack

Alertmanager receives alerts from Prometheus and routes them to receivers (Slack, PagerDuty, email).

```yaml
# alertmanager-values.yaml — add to prometheus helm upgrade
alertmanager:
  config:
    global:
      slack_api_url: "https://hooks.slack.com/services/YOUR/WEBHOOK/URL"

    route:
      group_by: ["alertname", "namespace"]
      group_wait: 30s
      group_interval: 5m
      repeat_interval: 12h
      receiver: "slack-critical"
      routes:
        - match:
            severity: critical
          receiver: "slack-critical"
        - match:
            severity: warning
          receiver: "slack-warnings"

    receivers:
      - name: "slack-critical"
        slack_configs:
          - channel: "#alerts-critical"
            title: "{{ .GroupLabels.alertname }}"
            text: "{{ range .Alerts }}{{ .Annotations.description }}{{ end }}"
            send_resolved: true

      - name: "slack-warnings"
        slack_configs:
          - channel: "#alerts-warnings"
            title: "{{ .GroupLabels.alertname }}"
            text: "{{ range .Alerts }}{{ .Annotations.summary }}{{ end }}"
            send_resolved: true
```

```bash
helm upgrade prometheus prometheus-community/prometheus \
  -f alertmanager-values.yaml

# Check Alertmanager UI
minikube service prometheus-alertmanager-ext --url
```

---

## Health Checks: Liveness, Readiness, and Startup Probes

These are the Kubernetes-native health mechanism that work alongside Prometheus monitoring. They control traffic routing (readiness) and container restarts (liveness).

### Current probe config for part-inventory-service

```yaml
containers:
  - name: part-inventory-service
    startupProbe:
      httpGet:
        path: /actuator/health/readiness
        port: 8080
      failureThreshold: 30      # 30 × 10s = 5 minutes for JVM startup
      periodSeconds: 10
    livenessProbe:
      httpGet:
        path: /actuator/health/liveness
        port: 8080
      initialDelaySeconds: 0    # startup probe guards this, so 0 is fine
      periodSeconds: 10
      failureThreshold: 3       # restart after 3 consecutive failures (30s)
    readinessProbe:
      httpGet:
        path: /actuator/health/readiness
        port: 8080
      periodSeconds: 5
      failureThreshold: 3       # remove from Service endpoints after 15s
```

### What each probe does

| Probe | On failure | Effect |
| ----- | ---------- | ------ |
| `startupProbe` | Blocks liveness/readiness until it passes | Protects slow-starting JVMs from premature liveness kills |
| `livenessProbe` | Container is killed and restarted | Recovers from deadlocks, unresponsive state |
| `readinessProbe` | Pod removed from Service Endpoints | Zero-downtime during rolling updates; stops traffic to unhealthy pods |

### Spring Boot Actuator health groups

Spring Boot maps liveness and readiness to separate health endpoints automatically:

```bash
# Liveness — is the JVM alive? (checks internal state)
curl http://localhost:8080/actuator/health/liveness
# {"status":"UP","components":{"livenessState":{"status":"UP"}}}

# Readiness — is the app ready to serve traffic? (checks DB connection, etc.)
curl http://localhost:8080/actuator/health/readiness
# {"status":"UP","components":{"readinessState":{"status":"UP"},"db":{"status":"UP"}}}
```

When the database is down, `readiness` returns `DOWN` → pod removed from Service endpoints → traffic stops. `liveness` remains `UP` → pod is not restarted (restarting won't fix a DB outage).

---

## Observing Health Checks via Prometheus

Kubernetes probe results appear in `kube_pod_container_status_ready` and restart counters:

```promql
# Pods currently failing readiness
kube_pod_status_ready{condition="false", namespace="inventory-service"}

# Restart count per container (rising counter = CrashLoop or liveness failures)
increase(kube_pod_container_status_restarts_total{namespace="inventory-service"}[1h])

# Pods that have restarted more than 5 times total
kube_pod_container_status_restarts_total{namespace="inventory-service"} > 5
```

---

## Lab — Trigger and Observe an Alert

### Step 1 — Confirm Prometheus is scraping the services

```bash
# Port-forward Prometheus
kubectl port-forward svc/prometheus-server 9090:80 &

# Open http://localhost:9090/targets
# part-inventory-service and part-order-service should show State: UP
```

### Step 2 — Inject a failure and watch the alert fire

```bash
# Scale inventory to 0 — pods disappear, order service calls will fail
kubectl scale deployment part-inventory-service -n inventory-service --replicas=0

# In Prometheus UI → Alerts tab — watch PodNotReady transition:
# INACTIVE → PENDING (for: 2m) → FIRING
```

### Step 3 — Observe in Grafana

```bash
# Port-forward Grafana
kubectl port-forward svc/grafana 3000:80 &
# Open http://localhost:3000 (admin / admin123)
```

1. Open the **Kubernetes Cluster Overview** dashboard — pod count drops
2. Open **Explore → Prometheus** — run: `kube_pod_status_ready{condition="false"}`
3. Open **Explore → Loki** — query: `{app="part-order-service"} |= "Connection refused"`

### Step 4 — Restore and watch recovery

```bash
kubectl scale deployment part-inventory-service -n inventory-service --replicas=2

# Alert transitions FIRING → RESOLVED after readiness probe passes
# Prometheus sends resolved notification to Alertmanager
```

---

## Grafana Alerting (UI-based Alerts)

Grafana can also evaluate alert conditions and send notifications independently of Alertmanager.

```text
Grafana UI → Alerting → Alert Rules → New Alert Rule

Query A: 
  sum(rate(http_server_requests_seconds_count{status=~"5.."}[5m]))
  /
  sum(rate(http_server_requests_seconds_count[5m]))

Condition: IS ABOVE  0.01

Evaluation: every 1m, for 2m

Labels:  severity=critical
         service=part-inventory-service

Notification: contact point → Slack webhook
```

Grafana alerting is useful for dashboard-driven alerts (tied to panel queries). For infrastructure alerts (node down, pod OOMKilled), Prometheus alert rules are the standard.

---

## Verification Commands

```bash
# Check Prometheus targets (scraping status)
curl http://localhost:9090/api/v1/targets | jq '.data.activeTargets[] | {job:.labels.job, health:.health}'

# List active alerts
curl http://localhost:9090/api/v1/alerts | jq '.data.alerts[] | {name:.labels.alertname, state:.state}'

# Alertmanager — current alerts being routed
curl http://localhost:9093/api/v1/alerts | jq '.data[].labels'

# Grafana datasource health
curl -u admin:admin123 http://localhost:3000/api/datasources | jq '.[].name'

# Pod restart counts
kubectl get pods -n inventory-service -o custom-columns="NAME:.metadata.name,RESTARTS:.status.containerStatuses[0].restartCount"

# Events (probe failures show up here)
kubectl get events -n inventory-service --sort-by='.lastTimestamp' | tail -20
```
