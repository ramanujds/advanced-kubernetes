# Service Meshes — The Problem and the Solution

## The Microservices Communication Problem

When you break a monolith into microservices, you gain deployment independence but inherit a new category of problems. Every service call that was an in-process function call is now a network request — with all the failure modes that brings.

```text
Monolith (simple)              Microservices (complex)
─────────────────              ───────────────────────
order → inventory              order-service ──HTTP──► inventory-service
  (function call)                            ◄──────── (network, can fail)
  no latency                               latency, timeouts, retries needed
  no auth needed                           auth? mTLS? who called me?
  no tracing needed                        which hop is slow? where did it fail?
```

With 10+ services calling each other, these problems multiply:

| Problem | Without a mesh | With a mesh |
| ------- | -------------- | ----------- |
| **Encryption** | Each team implements TLS or leaves traffic plain | Automatic mTLS between all pods |
| **Retries / timeouts** | Coded per service, inconsistent | Configured in policy, applied uniformly |
| **Circuit breaking** | Library per language (Hystrix, Resilience4j) | Mesh-level, language-agnostic |
| **Observability** | Each service emits its own metrics/traces | Automatic golden signals for every call |
| **Traffic control** | Application restarts needed for canary | Policy change, zero redeploy |
| **Authorization** | Custom auth logic in each service | Declare "who can call whom" in YAML |

---

## What a Service Mesh Is

A service mesh is an infrastructure layer that handles **all inter-service communication** without changing application code.

It does this by injecting a **sidecar proxy** (Envoy) into every pod. All traffic in and out of a pod goes through that proxy. The mesh control plane configures what each proxy does.

```text
┌──────────────────────────────────────────────────────────┐
│  Control Plane (Istiod)                                   │
│  - Distributes config to all proxies                      │
│  - Manages certificates                                   │
│  - Collects telemetry                                     │
└──────────────────────┬───────────────────────────────────┘
                       │ xDS API
         ┌─────────────┼─────────────┐
         ▼             ▼             ▼
┌──────────────┐ ┌──────────────┐ ┌──────────────┐
│ Pod          │ │ Pod          │ │ Pod          │
│ ┌──────────┐ │ │ ┌──────────┐ │ │ ┌──────────┐ │
│ │  App     │ │ │ │  App     │ │ │ │  App     │ │
│ └────┬─────┘ │ │ └────┬─────┘ │ │ └────┬─────┘ │
│ ┌────▼─────┐ │ │ ┌────▼─────┐ │ │ ┌────▼─────┐ │
│ │  Envoy   │ │ │ │  Envoy   │ │ │ │  Envoy   │ │
│ │  Proxy   │ │ │ │  Proxy   │ │ │ │  Proxy   │ │
│ └──────────┘ │ │ └──────────┘ │ │ └──────────┘ │
└──────────────┘ └──────────────┘ └──────────────┘
   order-service    inventory-svc     mysql
```

The app talks to `localhost`. The proxy intercepts the traffic via iptables rules and applies the mesh policy — mTLS, retries, tracing headers — transparently.

---

## Core Capabilities

### 1. Mutual TLS (mTLS)

Every service gets a SPIFFE-based identity (X.509 certificate). Proxies negotiate mTLS automatically for every service-to-service call.

- Traffic is encrypted in transit even inside the cluster
- Each service cryptographically proves its identity — "I am `inventory-service` in namespace `inventory-service`"
- No application code change needed

### 2. Observability — The Four Golden Signals Automatically

Without instrumentation, the mesh provides for every service:

```text
Latency   — P50/P95/P99 response times per route
Traffic   — requests per second
Errors    — 4xx/5xx rates
Saturation — concurrent connections, queue depth
```

These come from the Envoy proxy's built-in stats, not from application logs.

### 3. Traffic Management

Control how traffic flows between service versions — without touching application code:

- **Canary**: send 5% of traffic to v2
- **A/B testing**: route users with header `X-Beta: true` to v2
- **Fault injection**: inject 500ms latency or HTTP 503 into 10% of calls to test resilience
- **Circuit breaking**: stop sending traffic to a service that is consistently failing

### 4. Authorization Policy

Declare "which services are allowed to call which" at the mesh level:

```yaml
# Only order-service can call inventory-service
# All other callers are denied — even inside the cluster
```

This is zero-trust networking: default deny, explicit allow.

---

## Service Mesh Options

| Mesh | Proxy | Complexity | Best for |
| ---- | ----- | ---------- | -------- |
| **Istio** | Envoy | High | Full-featured, enterprise |
| **Linkerd** | Linkerd-proxy (Rust) | Low | Simplicity, low overhead |
| **Consul Connect** | Envoy | Medium | Multi-cluster, multi-cloud |
| **Cilium** | eBPF (no sidecar) | Medium | Performance, kernel-level |
| **AWS App Mesh** | Envoy | Low | EKS-native, managed |

This training covers **Istio** — the most widely deployed mesh and the reference implementation.

See [istio.md](istio.md) for the full Istio setup and examples.

---

## Do You Actually Need a Service Mesh?

A mesh adds real operational complexity: double the containers, extra CPU/memory per pod, another control plane to manage.

**Use a mesh when you have:**

- Strict compliance or audit requirements for encryption in transit
- 5+ services calling each other (observability cost pays off)
- Multi-team platform where you can't trust every team to implement retries/timeouts correctly
- Traffic shifting needs (canary, A/B) without redeploying services

**A mesh is overkill when you have:**

- A single service or simple 2-3 service architecture
- A team that can consistently implement resilience patterns in code
- Limited cluster resources (sidecars cost ~50-100MB RAM per pod)

Linkerd is a lighter alternative for teams that want the observability benefit without Istio's complexity.
