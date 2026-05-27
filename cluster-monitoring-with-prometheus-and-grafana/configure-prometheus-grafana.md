
# Steps to Configure Prometheus and Grafana on Kubernetes

## 1. Add Helm Repositories

```sh
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
```

## 2. Install Prometheus

```sh
helm install prometheus prometheus-community/prometheus --version 27.8.0
```

## 3. Install Grafana

```sh
helm install grafana grafana/grafana --version 8.12.0 -f grafana-values.yaml
```

## 4. Create Services to Expose Grafana

```sh
kubectl apply -f grafana-nodeport.yaml
```



## 5. Configure Grafana

1. Open Grafana in your browser using the URL from above.
2. Create a new dashboard:
    - Go to **Create** → **Import Dashboard**.
    - Input dashboard ID: `15661`.
    - Set the data source to **Prometheus**.

---

## 6. Add Loki for Log Aggregation (Sidecar Pattern)

### Install Loki via Helm

```sh
helm repo add grafana https://grafana.github.io/helm-charts
helm repo update
helm install loki grafana/loki --version 6.29.0 -f loki-values.yaml
```

Loki will be available inside the cluster at `http://loki:3100`.

### Upgrade Grafana to add the Loki datasource

This upgrades the existing Grafana release and provisions both Prometheus and Loki as datasources automatically — no manual UI setup needed.

```sh
helm upgrade grafana grafana/grafana --version 8.12.0 -f grafana-values.yaml
```

### Deploy the Promtail sidecar ConfigMap

Promtail runs as a sidecar in each Spring Boot pod. It reads log files from a shared volume and ships them to Loki.

```sh
kubectl apply -f ../kuberneters-manifests/promtail-configmap.yaml
```

### Deploy the updated app manifests (with sidecar)

Each pod now has two containers: the Spring Boot app and a Promtail sidecar sharing an `emptyDir` volume at `/var/log/app`.

```sh
kubectl apply -f ../kuberneters-manifests/part-inventory-deployment.yaml
kubectl apply -f ../kuberneters-manifests/part-order-deployment.yaml
```

### Verify sidecar is running

```sh
# Both containers (app + promtail) should show as READY 2/2
kubectl get pods

# Tail Promtail logs to confirm it is shipping to Loki
kubectl logs <pod-name> -c promtail -f
```

### Query logs in Grafana

1. Open Grafana → **Explore**
2. Select **Loki** from the datasource dropdown
3. Use LogQL to query:

```logql
# All logs from the inventory service
{app="part-inventory-service"}

# Only ERROR logs from the order service
{app="part-order-service", level="ERROR"}

# Filter by log message content
{app="part-inventory-service"} |= "place-order"
```

### How it works

```text
Spring Boot app
  │  writes via logback-spring.xml
  ▼
/var/log/app/application.log   ← emptyDir volume (shared within pod)
  ▲
Promtail sidecar
  │  ships log lines with labels: app=<service-name>, level=INFO|ERROR|...
  ▼
Loki (http://loki:3100)
  ▲
Grafana Explore / Dashboards
```

The `LOG_PATH=/var/log/app` env var in each deployment tells Spring Boot's `logback-spring.xml` where to write. Locally (without the env var) logs default to `./logs/`.
