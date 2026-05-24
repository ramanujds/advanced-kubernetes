# Kubernetes Networking Fundamentals

## The Mental Model

Kubernetes networking is built on four flat rules. Every other concept is a consequence of these:

1. Every pod gets its own IP address
2. Pods on the same node communicate without NAT
3. Pods on different nodes communicate without NAT
4. The IP a pod sees itself as is the same IP other pods use to reach it

This is called the **Kubernetes network model**. It is not TCP/IP reimagined — it is a requirement imposed on whichever network plugin you install.

---

## The Networking Stack

```text
┌─────────────────────────────────────────────────────────┐
│  Application Layer         Services, Ingress, DNS        │
├─────────────────────────────────────────────────────────┤
│  Kubernetes Layer          kube-proxy, CoreDNS           │
├─────────────────────────────────────────────────────────┤
│  CNI Plugin Layer          Calico / Flannel / Cilium     │
├─────────────────────────────────────────────────────────┤
│  OS / Kernel Layer         iptables / eBPF / VXLAN       │
└─────────────────────────────────────────────────────────┘
```

Your YAML operates at the top two layers. CNI operates at the third. The OS handles packets at the fourth. You configure the top; CNI owns the middle.

---

## What a CNI Plugin Does

CNI (Container Network Interface) is a spec, not software. When kubelet creates a pod, it calls the configured CNI plugin to:

1. Create a virtual network interface (`veth` pair) for the pod
2. Assign an IP from the pod CIDR
3. Set up routing so that IP is reachable from any node in the cluster

Without a CNI plugin, pods get no IP and stay in `ContainerCreating`.

---

## CNI Plugins Comparison

| Plugin | Model | Network Policy | Encryption | Best for |
| ------ | ----- | -------------- | ---------- | -------- |
| **Flannel** | Overlay (VXLAN) | No (needs Calico addon) | No | Simple clusters, learning |
| **Calico** | Routing (BGP) or Overlay | Yes (full NetworkPolicy) | Optional (WireGuard) | Production, security-first |
| **Cilium** | eBPF (no iptables) | Yes (extended policy) | Yes (WireGuard) | High-perf, observability |
| **Weave** | Overlay (mesh) | Yes | Yes | Multi-cluster mesh |

Minikube uses Kindnet by default (a simple Flannel variant). GKE uses its own VPC-native CNI. EKS uses `vpc-cni` (pods get VPC IPs directly).

### Verify Which CNI is Running

```bash
# Look for the CNI pod in kube-system
kubectl get pods -n kube-system

# On advanced-k8s minikube cluster (kindnet)
kubectl get pods -n kube-system | grep -E "calico|flannel|cilium|kindnet|weave"

# Check the CNI config on a node
kubectl get node advanced-k8s -o jsonpath='{.metadata.annotations}' | jq .

# Or inspect the CNI config directory
minikube ssh --profile=advanced-k8s -- ls /etc/cni/net.d/
minikube ssh --profile=advanced-k8s -- cat /etc/cni/net.d/10-kindnet.conflist
```

---

## Step 1 — Explore the Cluster Network Layout

Before testing connectivity, understand the IP ranges:

```bash
# Pod CIDR — the IP range pods are assigned from
kubectl get nodes -o jsonpath='{.items[*].spec.podCIDR}' | tr ' ' '\n'
# 10.244.0.0/24   ← advanced-k8s (control plane)
# 10.244.1.0/24   ← advanced-k8s-m02
# 10.244.2.0/24   ← advanced-k8s-m03
# 10.244.3.0/24   ← advanced-k8s-m04

# Service CIDR — ClusterIPs come from here
kubectl cluster-info dump | grep -m1 service-cluster-ip-range

# DNS cluster IP (CoreDNS)
kubectl get svc -n kube-system kube-dns
```

Each node gets a `/24` slice of the pod CIDR. The CNI plugin routes between these slices.

---

## Step 2 — Inspect Pod Networking

Deploy the inventory and order services to generate real pods:

```bash
kubectl apply -f kuberneters-manifests/

# Get pod IPs — note which node each pod is on
kubectl get pods -A -o wide
```

Inspect the network interface inside a running pod:

```bash
# Exec into the inventory pod
POD=$(kubectl get pods -n inventory-service -o jsonpath='{.items[0].metadata.name}')
kubectl exec -it $POD -n inventory-service -- sh

# Inside the pod
ip addr                    # shows eth0 with the pod IP
ip route                   # default route via the node's bridge
cat /etc/resolv.conf       # nameserver points to CoreDNS (kube-dns ClusterIP)
```

The pod IP is in the node's `/24` block. The default route points to a virtual bridge managed by the CNI plugin.

---

## Step 3 — Same-Node Pod-to-Pod Communication

When two pods are on the same node, packets travel through the node's virtual bridge — no physical network involved.

```text
Pod A (10.244.2.10) ──veth──► cbr0 (bridge) ──veth──► Pod B (10.244.2.11)
```

### Lab: Deploy two pods on the same node

```bash
# Deploy a debug pod on a specific node alongside the inventory pod
kubectl apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: netshoot
  namespace: inventory-service
spec:
  nodeName: advanced-k8s-m02
  containers:
    - name: netshoot
      image: nicolaka/netshoot
      command: ["sleep", "3600"]
EOF

# Get the inventory pod IP on m02
kubectl get pods -n inventory-service -o wide | grep m02

# Exec into netshoot and ping the inventory pod directly by IP
kubectl exec -it netshoot -n inventory-service -- ping -c 3 <inventory-pod-ip>

# Confirm same-node — no hop through the physical network
kubectl exec -it netshoot -n inventory-service -- traceroute <inventory-pod-ip>
# Should show: 1 hop only (the bridge)
```

---

## Step 4 — Cross-Node Pod-to-Pod Communication

When two pods are on different nodes, the CNI plugin routes packets via the overlay or BGP. On Flannel/Kindnet this means VXLAN encapsulation.

```text
Pod A (node m02, 10.244.2.10)
  │
  ▼
  veth → cbr0 → flannel.1 (VXLAN encap)
  │
  ▼  [physical network]
  │
  ▼
flannel.1 (VXLAN decap) → cbr0 → veth
  │
  ▼
Pod B (node m03, 10.244.3.10)
```

### Lab: Cross-node ping

```bash
# Get an inventory pod IP on m03
kubectl get pods -n inventory-service -o wide | grep m03
# Example: 10.244.3.15

# From the netshoot pod on m02, ping the pod on m03
kubectl exec -it netshoot -n inventory-service -- ping -c 3 10.244.3.15

# Traceroute shows 2 hops: bridge → node → bridge
kubectl exec -it netshoot -n inventory-service -- traceroute 10.244.3.15
```

The ping works — the CNI plugin has programmed routes on both nodes so they can reach each other's pod CIDRs.

---

## Step 5 — Pod-to-Pod via Service (The Real Pattern)

In production, pods never talk to each other by IP directly — IPs are ephemeral and change when pods restart. Services provide a stable virtual IP (ClusterIP) that kube-proxy maintains.

```text
order-service pod
    │
    ▼ HTTP request to http://part-inventory-service:8080
    │
CoreDNS resolves part-inventory-service → 10.96.45.100 (ClusterIP)
    │
kube-proxy (iptables/ipvs rule) maps ClusterIP → one of the pod IPs
    │
    ▼
inventory-service pod (10.244.2.15)
```

### Lab: Verify DNS resolution and service routing

```bash
# From netshoot, resolve the service DNS name
kubectl exec -it netshoot -n inventory-service -- nslookup part-inventory-service
# Shows: part-inventory-service.inventory-service.svc.cluster.local → 10.96.xx.xx

# Full DNS name works cross-namespace too
kubectl exec -it netshoot -n inventory-service -- \
  nslookup part-order-service.order-service.svc.cluster.local

# curl the inventory service by DNS name
kubectl exec -it netshoot -n inventory-service -- \
  curl -s http://part-inventory-service:8080/api/parts | jq .
```

### How kube-proxy Maps ClusterIP to Pod IPs

```bash
# View iptables rules for the inventory service (run on a node)
minikube ssh --profile=advanced-k8s-m02 -- \
  sudo iptables -t nat -L KUBE-SERVICES -n | grep inventory

# Or view ipvs entries (if kube-proxy is in ipvs mode)
minikube ssh --profile=advanced-k8s-m02 -- sudo ipvsadm -Ln | grep -A2 <cluster-ip>
```

Each pod endpoint appears as an iptables DNAT rule. When traffic hits the ClusterIP, iptables randomly selects one of the healthy pod IPs (this is the built-in load balancing).

---

## Step 6 — CoreDNS: Service Discovery

CoreDNS is the in-cluster DNS server. Every pod is configured to use it (see `/etc/resolv.conf`).

### DNS Name Format

```text
<service>.<namespace>.svc.cluster.local
<pod-ip-dashes>.<namespace>.pod.cluster.local
```

Short names work within the same namespace due to the `search` entries in `/etc/resolv.conf`:

```bash
kubectl exec -it netshoot -n inventory-service -- cat /etc/resolv.conf
# nameserver 10.96.0.10          ← CoreDNS ClusterIP
# search inventory-service.svc.cluster.local svc.cluster.local cluster.local
# options ndots:5
```

`ndots:5` means if a name has fewer than 5 dots, the resolver appends each search domain. `part-inventory-service` becomes `part-inventory-service.inventory-service.svc.cluster.local` automatically.

### Verify CoreDNS

```bash
# CoreDNS pods
kubectl get pods -n kube-system -l k8s-app=kube-dns

# CoreDNS ConfigMap (shows zones and plugins)
kubectl get configmap coredns -n kube-system -o yaml

# Test DNS from inside a pod
kubectl exec -it netshoot -n inventory-service -- \
  nslookup kubernetes.default.svc.cluster.local
# Should return: 10.96.0.1 (the Kubernetes API server ClusterIP)
```

---

## Step 7 — Observe the Full Flow End to End

Trigger an actual order and watch traffic flow across the cluster:

```bash
# Port-forward the order service locally
kubectl port-forward svc/part-order-service 8082:80 -n order-service &

# Place an order (triggers order-service → inventory-service communication)
curl -s -X POST http://localhost:8082/api/part-orders/place-order \
  -H "Content-Type: application/json" \
  -d '{"partSku":"SKU-001","quantity":2}' | jq .

# Watch both pods log the request
kubectl logs -f deployment/part-order-service -n order-service &
kubectl logs -f deployment/part-inventory-service -n inventory-service
```

The request travels:

1. `localhost:8082` → port-forward → order-service pod
2. Order-service Feign client → DNS lookup → `part-inventory-service.inventory-service.svc.cluster.local`
3. CoreDNS → ClusterIP
4. kube-proxy iptables → inventory-service pod IP
5. Cross-node if pods are on different nodes (VXLAN encap/decap via CNI)
6. Response travels back the same path

---

## Network Troubleshooting Commands

```bash
# Is the pod getting an IP?
kubectl get pod <name> -n <ns> -o wide
# If IP is empty → CNI issue; check CNI pod logs in kube-system

# Can pods reach each other?
kubectl exec -it <pod> -n <ns> -- ping <other-pod-ip>
kubectl exec -it <pod> -n <ns> -- curl -v http://<service>:<port>/health

# DNS not resolving?
kubectl exec -it <pod> -n <ns> -- nslookup <service>
# If NXDOMAIN → check service name and namespace spelling
# If timeout → CoreDNS pods may be down

# Check CoreDNS logs
kubectl logs -n kube-system -l k8s-app=kube-dns --tail=30

# Service has no endpoints (pods not matching selector)?
kubectl get endpoints <service-name> -n <ns>
# Empty ENDPOINTS column means label selector doesn't match any pod

# iptables rules for a service
kubectl get svc <service-name> -n <ns>   # get ClusterIP
minikube ssh --profile=advanced-k8s -- sudo iptables -t nat -L -n | grep <cluster-ip>

# Packet capture on a node (requires tcpdump)
minikube ssh --profile=advanced-k8s-m02 -- \
  sudo tcpdump -i eth0 -n host <pod-ip> -w /tmp/cap.pcap
```

---

## Common Issues

| Issue | Symptom | Cause | Fix |
| ----- | ------- | ----- | --- |
| Pod stuck `ContainerCreating` | No IP assigned | CNI plugin not running | Check `kubectl get pods -n kube-system`; restart CNI pod |
| Cross-node ping fails | Same-node works, cross-node doesn't | CNI routing not programmed | Check CNI pod logs; verify node routes (`ip route show`) |
| DNS not resolving | `nslookup` returns SERVFAIL | CoreDNS down or misconfigured | Check CoreDNS pod status and logs |
| Service returns connection refused | Service IP reachable, port not | Wrong `targetPort` in Service spec | Verify `containerPort` matches `targetPort` in Service |
| Service returns no route to host | ClusterIP unreachable | kube-proxy not running | Check `kubectl get pods -n kube-system \| grep kube-proxy` |
| Intermittent failures | 1 in 3 requests fail | One pod failing health check but still receiving traffic | Add readiness probe; fix the unhealthy pod |
