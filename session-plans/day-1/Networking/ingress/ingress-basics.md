# Ingress and Ingress Controllers

## The Problem Ingress Solves

Without Ingress, exposing services externally requires:

- `NodePort` — exposes a random high port per service (30082, 30083 …) — not production-friendly
- `LoadBalancer` — one cloud load balancer **per service** — expensive at scale

With Ingress you get one entry point that routes to any number of services based on hostname or path.

```text
Without Ingress                        With Ingress
──────────────────────────────         ────────────────────────────────
:30080 → part-inventory-service        api.company.com/inventory → inventory-service
:30082 → part-order-service            api.company.com/orders    → order-service
:30083 → payment-service               api.company.com/payments  → payment-service
(3 cloud LBs, 3 ports)                 (1 cloud LB, path-based routing)
```

---

## Ingress vs Ingress Controller

| Object | What it is | Who creates it |
| ------ | ---------- | -------------- |
| `Ingress` | A routing rule (YAML config) | Application team |
| `Ingress Controller` | The reverse proxy that reads and enforces rules | Platform/infra team |

The `Ingress` resource does nothing without a running controller. Kubernetes does not ship one by default.

### Common Controllers

| Controller | Best for | Cloud native? |
| ---------- | -------- | ------------- |
| **NGINX Ingress** | All environments, most flexible | No (runs as pod) |
| **GCE Ingress** | GKE — uses Google Cloud HTTP(S) LB | Yes (GKE only) |
| **AWS ALB Controller** | EKS — uses Application Load Balancer | Yes (EKS only) |
| **Traefik** | Dynamic config, microservices | No |
| **Kong** | API gateway features | No |

---

## Setup: Install NGINX Ingress on advanced-k8s

```bash
# Enable the ingress addon (installs nginx ingress controller)
minikube addons enable ingress --profile=advanced-k8s

# Verify the controller pod is running
kubectl get pods -n ingress-nginx
# NAME                                        READY   STATUS
# ingress-nginx-controller-xxxx               1/1     Running

# Get the controller's external IP (on minikube, this is the node IP)
minikube ip --profile=advanced-k8s
# 192.168.49.2

kubectl get svc -n ingress-nginx
# ingress-nginx-controller   LoadBalancer  10.96.x.x  192.168.49.2  80:31080/TCP,443:31443/TCP
```

---

## Example 1 — Path-Based Routing

Route `/inventory` to `part-inventory-service` and `/orders` to `part-order-service` on a single host.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: parts-ingress
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/rewrite-target: /$2   # strips the path prefix
spec:
  ingressClassName: nginx
  rules:
    - host: parts.local
      http:
        paths:
          - path: /inventory(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: part-inventory-service
                port:
                  number: 80
          - path: /orders(/|$)(.*)
            pathType: ImplementationSpecific
            backend:
              service:
                name: part-order-service
                port:
                  number: 80
```

```bash
kubectl apply -f parts-ingress.yaml

# Add to /etc/hosts so the hostname resolves locally
echo "$(minikube ip --profile=advanced-k8s) parts.local" | sudo tee -a /etc/hosts

# Test
curl http://parts.local/inventory/api/parts
curl http://parts.local/orders/api/part-orders
```

### pathType Options

| pathType | Behaviour |
| -------- | --------- |
| `Exact` | Matches the path exactly — `/inventory` does not match `/inventory/` |
| `Prefix` | Prefix match on path segments — `/inventory` matches `/inventory/api/parts` |
| `ImplementationSpecific` | Controller-specific — NGINX supports regex with capture groups |

---

## Example 2 — Host-Based Routing

Two separate hostnames, each routing to a different service. Common for microservices with their own domains.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: parts-host-ingress
  namespace: default
spec:
  ingressClassName: nginx
  rules:
    - host: inventory.parts.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: part-inventory-service
                port:
                  number: 80
    - host: orders.parts.local
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: part-order-service
                port:
                  number: 80
```

```bash
# /etc/hosts entries
echo "$(minikube ip --profile=advanced-k8s) inventory.parts.local" | sudo tee -a /etc/hosts
echo "$(minikube ip --profile=advanced-k8s) orders.parts.local" | sudo tee -a /etc/hosts

curl http://inventory.parts.local/api/parts
curl http://orders.parts.local/api/part-orders
```

---

## Example 3 — TLS / HTTPS Termination

The Ingress controller terminates TLS — backends receive plain HTTP. The certificate lives in a Kubernetes Secret.

```bash
# Generate a self-signed certificate for local testing
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt \
  -subj "/CN=parts.local/O=parts"

# Create the TLS secret
kubectl create secret tls parts-tls --key=tls.key --cert=tls.crt
```

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: parts-tls-ingress
  namespace: default
  annotations:
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - parts.local
      secretName: parts-tls        # must be in the same namespace as the Ingress
  rules:
    - host: parts.local
      http:
        paths:
          - path: /inventory
            pathType: Prefix
            backend:
              service:
                name: part-inventory-service
                port:
                  number: 80
          - path: /orders
            pathType: Prefix
            backend:
              service:
                name: part-order-service
                port:
                  number: 80
```

```bash
kubectl apply -f parts-tls-ingress.yaml

# HTTPS request (ignore cert warning for self-signed)
curl -k https://parts.local/inventory/api/parts

# HTTP redirects to HTTPS automatically (ssl-redirect annotation)
curl -v http://parts.local/inventory/api/parts
# < HTTP/1.1 308 Permanent Redirect
# < Location: https://parts.local/inventory/api/parts
```

---

## Example 4 — Useful NGINX Annotations

Annotations control NGINX behaviour beyond the standard spec:

```yaml
metadata:
  annotations:
    # Rewrite /orders/api/part-orders → /api/part-orders on the backend
    nginx.ingress.kubernetes.io/rewrite-target: /$2

    # Increase timeout for long-running requests
    nginx.ingress.kubernetes.io/proxy-read-timeout: "120"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "120"

    # Rate limiting — 10 requests per second per IP
    nginx.ingress.kubernetes.io/limit-rps: "10"

    # Enable CORS for the inventory API
    nginx.ingress.kubernetes.io/enable-cors: "true"
    nginx.ingress.kubernetes.io/cors-allow-origin: "https://frontend.parts.local"

    # Force HTTPS
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
```

> Annotations are controller-specific. The same Ingress YAML with NGINX annotations will not work on GCE or AWS ALB controllers. This is one of the main motivations for Gateway API.

---

## Ingress on GKE (GCE Controller)

On GKE, the default controller is the GCE Ingress controller, which provisions a Google Cloud HTTP(S) Load Balancer automatically.

See [ingress-on-gke/part-order-ingress.yml](ingress-on-gke/part-order-ingress.yml) — the key difference is the annotation:

```yaml
metadata:
  annotations:
    kubernetes.io/ingress.class: "gce"    # uses the GCE controller
spec:
  rules:
    - http:
        paths:
          - path: /inventory
            pathType: Prefix
            backend:
              service:
                name: part-inventory-service
                port:
                  number: 80
          - path: /orders
            pathType: Prefix
            backend:
              service:
                name: part-order-service
                port:
                  number: 80
```

```bash
kubectl apply -f ingress-on-gke/part-order-ingress.yml

# GKE provisions an external HTTPS LB — takes 2-5 minutes
kubectl get ingress parts-ingress
# NAME            CLASS   HOSTS   ADDRESS           PORTS   AGE
# parts-ingress   gce     *       34.111.xxx.xxx    80      3m
```

The `ADDRESS` is a real public IP assigned by Google. No `/etc/hosts` tricks needed.

---

## Verification Commands

```bash
# List all Ingress resources across namespaces
kubectl get ingress -A

# Describe to see rules and backend health
kubectl describe ingress parts-ingress

# Check controller logs for routing decisions
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx --tail=50

# Watch real-time access logs
kubectl logs -n ingress-nginx -l app.kubernetes.io/name=ingress-nginx -f

# Inspect backend endpoints the controller resolved
kubectl get endpoints part-inventory-service
kubectl get endpoints part-order-service
```

---

## Ingress Limitations

These limitations motivated the Gateway API:

| Limitation | Detail |
| ---------- | ------ |
| HTTP/HTTPS only | No TCP, UDP, or gRPC routing in the core spec |
| Annotation sprawl | Every controller uses different annotation keys |
| Single resource owns everything | No role separation between infra and app teams |
| No traffic splitting in spec | Canary weights require controller-specific annotations |
| No request/response manipulation | Header modification, redirects are not standard |

See [gateway-api.md](gateway-api.md) for the modern solution.
