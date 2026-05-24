# Load Testing and Stress Testing Kubernetes Applications

## Why Load Test in Kubernetes?

A service that handles 100 RPS on a laptop may behave very differently in a cluster where:

- Pods have CPU/memory `requests` and `limits`
- Network hops go through kube-proxy, Ingress, or a service mesh
- HPA adds replicas under load — does it react fast enough?
- Downstream services (MySQL, inventory-service) become the bottleneck

Load testing in Kubernetes validates three things: **application correctness under load**, **autoscaler reaction time**, and **resource ceiling behavior** (what actually breaks first).

---

## Tools Overview

| Tool | Best for | How it runs |
| ---- | -------- | ----------- |
| **k6** | Scripted scenarios, thresholds, CI integration | Pod or local binary |
| **hey** | Quick ad-hoc load, single endpoint | Pod or local binary |
| **Locust** | Python-defined user behavior, web UI | Deployment in cluster |
| **wrk** | Raw HTTP throughput benchmarking | Pod |
| **Apache Bench (ab)** | Simple, available everywhere | Pod |

This guide focuses on **k6** (production-grade, scriptable) and **hey** (fast iteration).

---

## Tool 1 — hey (Quick Load Tests)

`hey` sends a fixed number of requests with concurrency control.

```bash
# Run hey as a pod inside the cluster (hits ClusterIP, no Ingress overhead)
kubectl run hey --image=williamyeh/hey --rm -it --restart=Never \
  -- -n 1000 -c 50 http://part-inventory-service.inventory-service/api/parts

# -n 1000   total requests
# -c 50     concurrent workers
```

Sample output:

```text
Summary:
  Total:        5.2 secs
  Slowest:      0.850 secs
  Fastest:      0.012 secs
  Average:      0.260 secs
  Requests/sec: 192.3

Response time histogram:
  0.012 [1]    |
  0.097 [120]  |■■■■■■■■
  0.182 [310]  |■■■■■■■■■■■■■■■■■■■■■
  0.267 [280]  |■■■■■■■■■■■■■■■■■■■
  ...

Status code distribution:
  [200] 998 responses
  [503] 2 responses       ← 2 failures worth investigating
```

### hey rate-limited test (simulate sustained RPS)

```bash
# 200 RPS for 30 seconds
kubectl run hey-rate --image=williamyeh/hey --rm -it --restart=Never \
  -- -q 200 -z 30s -c 20 \
  http://part-inventory-service.inventory-service/api/parts

# -q 200   rate limit to 200 RPS
# -z 30s   run for 30 seconds
# -c 20    concurrency
```

---

## Tool 2 — k6 (Scripted Scenarios)

k6 runs JavaScript test scripts that model realistic user behavior — ramp up, sustain, ramp down.

### Run k6 as a Kubernetes Job

```yaml
apiVersion: batch/v1
kind: Job
metadata:
  name: k6-load-test
  namespace: default
spec:
  template:
    spec:
      restartPolicy: Never
      containers:
        - name: k6
          image: grafana/k6:latest
          command: ["k6", "run", "/scripts/load-test.js"]
          volumeMounts:
            - name: scripts
              mountPath: /scripts
      volumes:
        - name: scripts
          configMap:
            name: k6-scripts
```

### k6 Script — Ramp Up to Find Breaking Point

```yaml
apiVersion: v1
kind: ConfigMap
metadata:
  name: k6-scripts
  namespace: default
data:
  load-test.js: |
    import http from 'k6/http';
    import { check, sleep } from 'k6';

    export const options = {
      stages: [
        { duration: '1m', target: 20 },   // ramp up to 20 VUs over 1 min
        { duration: '3m', target: 20 },   // hold at 20 VUs for 3 min
        { duration: '1m', target: 100 },  // ramp up to 100 VUs
        { duration: '3m', target: 100 },  // hold at 100 VUs
        { duration: '1m', target: 0 },    // ramp down
      ],
      thresholds: {
        http_req_duration: ['p(95)<500'],  // 95th percentile < 500ms
        http_req_failed: ['rate<0.01'],    // error rate < 1%
      },
    };

    export default function () {
      const res = http.get('http://part-inventory-service.inventory-service/api/parts');
      check(res, {
        'status is 200': (r) => r.status === 200,
        'response time < 500ms': (r) => r.timings.duration < 500,
      });
      sleep(1);
    }
```

```bash
# Apply and run
kubectl apply -f k6-scripts-configmap.yaml
kubectl apply -f k6-load-test-job.yaml

# Follow the test output
kubectl logs -f job/k6-load-test

# Watch HPA react during the test
kubectl get hpa -n inventory-service -w
```

### k6 Script — Order Flow (End-to-End)

Tests the full call chain: order-service → inventory-service → MySQL:

```yaml
  order-flow.js: |
    import http from 'k6/http';
    import { check } from 'k6';

    const BASE = 'http://part-order-service.order-service';

    export const options = {
      vus: 30,
      duration: '2m',
    };

    export default function () {
      // GET available parts (proxies to inventory)
      const partsRes = http.get(`${BASE}/api/part-orders/available-parts`);
      check(partsRes, { 'parts 200': (r) => r.status === 200 });

      // Place an order
      const payload = JSON.stringify({
        partSku: 'SKU-001',
        quantity: 1,
      });
      const orderRes = http.post(`${BASE}/api/part-orders/place-order`, payload, {
        headers: { 'Content-Type': 'application/json' },
      });
      check(orderRes, {
        'order 200 or 201': (r) => r.status === 200 || r.status === 201,
        'order has orderNumber': (r) => JSON.parse(r.body).orderNumber !== undefined,
      });
    }
```

---

## Stress Test: Find the Breaking Point

A stress test deliberately exceeds normal capacity to find what fails first.

### Approach: Step Load

```yaml
  stress-test.js: |
    import http from 'k6/http';
    import { check } from 'k6';

    export const options = {
      stages: [
        { duration: '2m', target: 50 },
        { duration: '2m', target: 100 },
        { duration: '2m', target: 200 },
        { duration: '2m', target: 400 },   // almost certainly breaks here
        { duration: '2m', target: 0 },
      ],
    };

    export default function () {
      const res = http.get('http://part-inventory-service.inventory-service/api/parts');
      check(res, { 'ok': (r) => r.status < 500 });
    }
```

### What to Watch During a Stress Test

In separate terminals while the test runs:

```bash
# Terminal 1 — HPA reaction
kubectl get hpa -n inventory-service -w

# Terminal 2 — Pod status (look for OOMKilled, CrashLoopBackOff)
kubectl get pods -n inventory-service -w

# Terminal 3 — Resource usage per pod
watch kubectl top pods -n inventory-service

# Terminal 4 — Error events
kubectl get events -n inventory-service --sort-by='.lastTimestamp' -w
```

### Interpreting Results

```text
Stage        VUs    RPS     p95     Error%   Replicas
─────────────────────────────────────────────────────
Ramp 50       50    45      120ms   0.0%     2
Hold 50       50    44      130ms   0.0%     2
Ramp 100     100    88      210ms   0.1%     4     ← HPA scaled out
Hold 100     100    85      250ms   0.2%     4
Ramp 200     200    140     480ms   2.1%     8     ← HPA at max, latency rising
Hold 200     200    130     920ms   8.4%     8     ← breaking point
Ramp 400     400     60    3200ms   34%      8     ← service degraded
```

Findings from this run:

- Breaking point is ~200 VUs with this pod size and HPA maxReplicas=8
- Action: either increase `maxReplicas` or increase pod CPU/memory `requests`

---

## Soak Test: Detect Memory Leaks and Slow Degradation

A soak test runs sustained moderate load for hours to detect gradual memory growth, connection pool exhaustion, or GC pressure.

```yaml
  soak-test.js: |
    import http from 'k6/http';
    import { check, sleep } from 'k6';

    export const options = {
      vus: 30,
      duration: '2h',           // run for 2 hours
      thresholds: {
        http_req_duration: ['p(95)<800'],
        http_req_failed: ['rate<0.005'],
      },
    };

    export default function () {
      const res = http.get('http://part-inventory-service.inventory-service/api/parts');
      check(res, { 'ok': (r) => r.status === 200 });
      sleep(1);
    }
```

Watch memory over time:

```bash
# Every 30 seconds, log memory per pod
while true; do
  echo "--- $(date) ---"
  kubectl top pods -n inventory-service
  sleep 30
done
```

If memory climbs steadily without levelling off — the service has a leak.

---

## Spike Test: Sudden Traffic Burst

Tests whether HPA reacts fast enough to absorb a sudden surge — models flash sales, scheduled batch jobs, viral events.

```yaml
  spike-test.js: |
    import http from 'k6/http';
    import { check } from 'k6';

    export const options = {
      stages: [
        { duration: '30s', target: 5 },    // baseline
        { duration: '10s', target: 200 },  // sudden spike
        { duration: '3m',  target: 200 },  // hold spike
        { duration: '10s', target: 5 },    // drop back
        { duration: '3m',  target: 5 },    // recovery
      ],
    };

    export default function () {
      const res = http.get('http://part-inventory-service.inventory-service/api/parts');
      check(res, { 'ok': (r) => r.status < 500 });
    }
```

HPA typically takes 30–60 seconds to react (metrics scrape interval + stabilization window). During that gap, the existing pods absorb the spike — their CPU limits become the buffer. Pre-scaling (setting a higher `minReplicas` before a known event) avoids this cold-start lag.

---

## Connecting Load Tests to HPA Tuning

After each test run, use the results to calibrate HPA:

```bash
# What CPU % did pods sustain during the test?
kubectl top pods -n inventory-service   # sample during the test

# How many replicas did HPA settle on at target load?
kubectl describe hpa part-inventory-hpa -n inventory-service | grep "desired replicas"
```

| Observation | Action |
| ----------- | ------ |
| HPA hits `maxReplicas` and errors increase | Raise `maxReplicas` or resize pods |
| HPA scales out slowly (>2 min lag) | Lower `scaleUp.stabilizationWindowSeconds` |
| Replicas oscillate up/down repeatedly | Raise `scaleDown.stabilizationWindowSeconds` |
| p95 latency high but CPU low | Bottleneck is DB or downstream — increase DB connection pool |
| OOMKilled pods during load | Increase memory `limits`; check VPA recommendation |

---

## Cleanup

```bash
# Remove load test resources
kubectl delete job k6-load-test
kubectl delete configmap k6-scripts
kubectl delete pod hey hey-rate 2>/dev/null || true
```

---

## Verification Commands

```bash
# HPA current state and recent events
kubectl describe hpa part-inventory-hpa -n inventory-service

# Pod resource usage during test
kubectl top pods -n inventory-service

# Events during the test (OOMKill, scale events, probe failures)
kubectl get events -n inventory-service --sort-by='.lastTimestamp'

# Check if any pods were OOMKilled
kubectl get pods -n inventory-service -o json | \
  jq '.items[].status.containerStatuses[].lastState.terminated | select(.reason=="OOMKilled")'
```
