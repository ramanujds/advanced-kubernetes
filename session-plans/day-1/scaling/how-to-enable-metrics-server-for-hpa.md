## Install Metrics Server

```bash

kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml

```

## Apply Patch

```bash

kubectl patch deployment metrics-server \
  -n kube-system \
  --type=json \
  -p='[
    {
      "op": "add",
      "path": "/spec/template/spec/containers/0/args/-",
      "value": "--kubelet-insecure-tls"
    }
  ]'

```

## Verify

```bash

kubectl get deployment metrics-server -n kube-system
# Should show READY 1/1

```
```bash
kubectl top nodes
# Should show CPU and memory usage for your node

```


Here is the complete solution to install Metrics Server using Helm, which is the cleanest and most maintainable approach for a local Docker Desktop cluster.

---

## Installing Metrics Server via Helm on Docker Desktop

### Step 1: Add the Metrics Server Helm Repo

```bash
helm repo add metrics-server https://kubernetes-sigs.github.io/metrics-server/
helm repo update
```

Verify the repo was added:

```bash
helm repo list
# Should show metrics-server listed
```

---

### Step 2: Install Metrics Server with the TLS Flag Pre-configured

This single command installs Metrics Server with `--kubelet-insecure-tls` already baked into the deployment — no patching needed afterward:

```bash
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set args="{--kubelet-insecure-tls}"
```

What each part does:

- `upgrade --install` — installs if not present, upgrades if already installed. Safe to run multiple times.
- `--namespace kube-system` — installs into the system namespace alongside other cluster components
- `--set args="{--kubelet-insecure-tls}"` — passes the critical flag that bypasses TLS certificate verification on Docker Desktop

---

### Step 3: Verify the Installation

```bash
# Check the pod is Running and 1/1 Ready
kubectl get pods -n kube-system | grep metrics-server

# Check the helm release is deployed
helm list -n kube-system
```

Expected output of `helm list`:

```
NAME            NAMESPACE   REVISION  STATUS    CHART
metrics-server  kube-system 1         deployed  metrics-server-3.x.x
```

---

### Step 4: Confirm Metrics Are Flowing

Wait about 60 seconds after installation, then:

```bash
kubectl top nodes
kubectl top pods
```

Expected output:

```
NAME             CPU(cores)   CPU%   MEMORY(bytes)   MEMORY%
docker-desktop   185m         4%     1740Mi          22%
```

Once this returns real numbers, your HPA `<unknown>` issue is resolved. Check your HPA:

```bash
kubectl get hpa
# TARGETS column should now show actual percentages like 3%/80%
```

---

### If You Had a Broken Metrics Server Already Installed

If you previously installed Metrics Server without the flag and it is stuck in `CrashLoopBackOff`, the `upgrade --install` command above will fix it in place:

```bash
helm upgrade --install metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --set args="{--kubelet-insecure-tls}"
```

Helm will roll out a new version of the deployment with the correct args. You can watch the rollout:

```bash
kubectl rollout status deployment/metrics-server -n kube-system
```

---

### Why Helm is Better Than Manual Patching

When you manually apply the YAML and then patch the deployment, you have two separate steps that can get out of sync — especially if the Metrics Server is updated or re-applied later, the patch gets wiped and you are back to `<unknown>`. With Helm, the `--kubelet-insecure-tls` flag is part of the release values, so it persists across upgrades and re-installs automatically.

To see the current values applied to your Helm release at any time:

```bash
helm get values metrics-server -n kube-system
```

To upgrade Metrics Server to a newer chart version while keeping your values:

```bash
helm upgrade metrics-server metrics-server/metrics-server \
  --namespace kube-system \
  --reuse-values
```

The `--reuse-values` flag ensures your `--kubelet-insecure-tls` setting is preserved during the upgrade.