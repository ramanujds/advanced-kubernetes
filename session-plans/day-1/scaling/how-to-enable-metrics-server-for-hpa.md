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