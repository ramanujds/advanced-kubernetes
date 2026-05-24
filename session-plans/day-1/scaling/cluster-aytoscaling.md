# Cluster Autoscaling

## The Problem HPA Alone Cannot Solve

HPA adds pod replicas when load increases. But if the cluster runs out of node capacity, the new pods stay `Pending` — HPA scaled out, but there is nowhere for the pods to run.

```text
Without Cluster Autoscaler:

Load spike → HPA creates 6 new pods
             ↓
  Pods stay Pending — no node has enough CPU left
  Service degrades despite HPA scaling

With Cluster Autoscaler:

Load spike → HPA creates 6 new pods
             ↓
  Pods Pending → CA detects unschedulable pods
             ↓
  CA provisions 2 new nodes
             ↓
  Pods scheduled and running in ~2 minutes
```

HPA scales **pods**. Cluster Autoscaler scales **nodes**. They work together.

---

## Cluster Autoscaler Architecture

```text
┌──────────────────────────────────────────────────┐
│  Cluster Autoscaler (pod in kube-system)          │
│                                                   │
│  Every 10 seconds:                                │
│  1. Are there Pending pods that don't fit?        │
│     → Scale UP: add nodes to the node group       │
│  2. Are there nodes with very low utilization     │
│     (< 50% for 10 minutes)?                       │
│     → Scale DOWN: cordon, drain, terminate node   │
└──────────────┬───────────────────────────────────┘
               │ cloud provider API
               ▼
  ┌────────────────────────────────┐
  │  Node Group / Auto-Scaling     │
  │  Group (GKE, EKS, AKS)        │
  │  min: 1  current: 3  max: 10  │
  └────────────────────────────────┘
```

CA is **cloud-provider aware** — it calls the cloud API to add/remove VM instances. It does not work on bare-metal without a cloud provider integration.

---

## Cluster Autoscaler on GKE

GKE has the deepest CA integration — it is a first-class feature, not a separate install.

### Enable on an existing cluster

```bash
# Enable CA on the default node pool
gcloud container clusters update advanced-k8s \
  --enable-autoscaling \
  --min-nodes=1 \
  --max-nodes=5 \
  --region=us-central1

# Verify
gcloud container clusters describe advanced-k8s \
  --region=us-central1 \
  --format="value(nodePools[0].autoscaling)"
# enabled: true
# maxNodeCount: 5
# minNodeCount: 1

# Check current node count
kubectl get nodes
```

### Create a cluster with autoscaling from the start

```bash
gcloud container clusters create advanced-k8s \
  --region=us-central1 \
  --machine-type=e2-standard-4 \
  --enable-autoscaling \
  --min-nodes=1 \
  --max-nodes=10 \
  --num-nodes=2
```

### GKE Node Auto-Provisioning (NAP)

NAP goes a step further than CA: instead of adding nodes to an existing pool, it creates **new node pools** with the right machine type for pending pods.

```bash
# Enable NAP (requires cluster-level autoscaling to be enabled first)
gcloud container clusters update advanced-k8s \
  --enable-autoprovisioning \
  --min-cpu=1 \
  --max-cpu=64 \
  --min-memory=1 \
  --max-memory=256 \
  --region=us-central1
```

With NAP, a pending GPU pod triggers GKE to automatically create a GPU node pool — no manual node pool management needed.

---

## Cluster Autoscaler on EKS

EKS uses the Cluster Autoscaler against EC2 Auto Scaling Groups (ASGs).

### Step 1 — Tag the ASG

CA discovers node groups by ASG tags:

```bash
# The ASG for your node group must have these tags
aws autoscaling create-or-update-tags \
  --tags \
    ResourceId=<asg-name> ResourceType=auto-scaling-group PropagateAtLaunch=false \
    Key=k8s.io/cluster-autoscaler/enabled Value=true \
    Key=k8s.io/cluster-autoscaler/advanced-k8s Value=owned
```

### Step 2 — IAM permissions for CA

```json
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "autoscaling:DescribeAutoScalingGroups",
        "autoscaling:DescribeAutoScalingInstances",
        "autoscaling:DescribeLaunchConfigurations",
        "autoscaling:DescribeScalingActivities",
        "autoscaling:SetDesiredCapacity",
        "autoscaling:TerminateInstanceInAutoScalingGroup",
        "ec2:DescribeImages",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplateVersions",
        "ec2:GetInstanceTypesFromInstanceRequirements"
      ],
      "Resource": "*"
    }
  ]
}
```

Attach this policy to the node group IAM role or use IRSA (IAM Roles for Service Accounts).

### Step 3 — Deploy the Cluster Autoscaler

```bash
# Download and apply the CA manifest for your Kubernetes version
kubectl apply -f https://raw.githubusercontent.com/kubernetes/autoscaler/master/cluster-autoscaler/cloudprovider/aws/examples/cluster-autoscaler-autodiscover.yaml

# Set the cluster name annotation
kubectl annotate serviceaccount cluster-autoscaler \
  -n kube-system \
  eks.amazonaws.com/role-arn=arn:aws:iam::<account-id>:role/ClusterAutoscalerRole

# Patch the deployment with your cluster name
kubectl patch deployment cluster-autoscaler \
  -n kube-system \
  --patch '{"spec":{"template":{"spec":{"containers":[{
    "name":"cluster-autoscaler",
    "command":["./cluster-autoscaler",
      "--v=4",
      "--stderrthreshold=info",
      "--cloud-provider=aws",
      "--skip-nodes-with-local-storage=false",
      "--expander=least-waste",
      "--node-group-auto-discovery=asg:tag=k8s.io/cluster-autoscaler/enabled,k8s.io/cluster-autoscaler/advanced-k8s",
      "--balance-similar-node-groups",
      "--skip-nodes-with-system-pods=false"
    ]}]}}}}'
```

---

## Cluster Autoscaler on Minikube (Local Simulation)

Minikube does not support real CA (no cloud provider), but you can observe the scale-up problem manually:

```bash
# Check how many nodes are available
kubectl get nodes

# Force a Pending state by deploying more pods than the cluster can fit
kubectl create deployment overload \
  --image=nginx \
  --replicas=20

kubectl get pods -w
# Some pods will be Pending if the cluster is at capacity

# Check why a pod is Pending
kubectl describe pod <pending-pod-name>
# Events:
#   Warning  FailedScheduling  0/1 nodes are available:
#            1 Insufficient cpu.
```

For hands-on CA testing, use GKE or a cloud provider where CA can actually provision nodes.

---

## Scale-Up: How CA Decides to Add a Node

When a pod is `Pending` due to insufficient resources, CA:

1. Identifies which pods are unschedulable
2. Simulates adding a new node from each available node group
3. Picks the node group that would schedule the most pending pods at the lowest cost (`least-waste` expander)
4. Calls the cloud API to add a node
5. Waits for the node to join the cluster (typically 1–3 minutes on GKE/EKS)

```bash
# Watch CA logs to see its decisions
kubectl logs -n kube-system -l app=cluster-autoscaler --tail=50 -f

# Sample log output during scale-up:
# I0525 scale_up.go:300] Scale-up: setting group size to 4
# I0525 scale_up.go:455] Final scale-up plan: [{NodeGroup: +1 node}]
```

---

## Scale-Down: How CA Decides to Remove a Node

CA removes a node only when all of these conditions are met:

| Condition | Detail |
| --------- | ------ |
| Node utilization < 50% | CPU + memory requests / allocatable < threshold |
| Low utilization for 10 minutes | Consecutive checks, not a single reading |
| All pods can be rescheduled elsewhere | No pod would be permanently unschedulable |
| No PodDisruptionBudget blocks the drain | PDB `minAvailable` must be satisfiable |
| No pods with `cluster-autoscaler.kubernetes.io/safe-to-evict: "false"` annotation | These pods block scale-down |

```bash
# Annotate a pod to prevent its node from being scaled down
kubectl annotate pod <pod-name> -n inventory-service \
  cluster-autoscaler.kubernetes.io/safe-to-evict="false"
```

Use this annotation carefully — it permanently prevents scale-down of whatever node the pod is on.

---

## PodDisruptionBudgets — Protecting Services During Scale-Down

When CA scales down, it drains the node. PDBs ensure the drain doesn't leave the service with too few replicas.

```yaml
apiVersion: policy/v1
kind: PodDisruptionBudget
metadata:
  name: part-inventory-pdb
  namespace: inventory-service
spec:
  minAvailable: 2             # at least 2 replicas must be running during any disruption
  selector:
    matchLabels:
      app: part-inventory-service
```

```bash
kubectl apply -f kubernetes-manifests/pdb-inventory.yaml

# Check PDB status — shows allowed disruptions
kubectl get pdb -n inventory-service
# NAME                   MIN AVAILABLE   MAX UNAVAILABLE   ALLOWED DISRUPTIONS   AGE
# part-inventory-pdb     2               N/A               1                     5m
# ALLOWED DISRUPTIONS: 1 → CA can drain 1 pod from this service
```

If `ALLOWED DISRUPTIONS` is 0, CA will not drain the node — it is blocked by the PDB. This is the safety net that prevents CA from taking down the last replica of a service.

---

## Expanders: How CA Chooses Which Node Group to Grow

When multiple node groups can schedule the pending pods, the **expander** decides which one to grow:

| Expander | Strategy | Use when |
| -------- | -------- | -------- |
| `least-waste` (default) | Picks the group that wastes the least CPU/memory | General use |
| `random` | Picks randomly | Spreading load across groups |
| `most-pods` | Picks the group that schedules the most pending pods | Burst workloads |
| `price` | Picks the cheapest node group (GKE only) | Cost-sensitive clusters |
| `priority` | Uses a configurable priority order | Spot/preemptible node preference |

```bash
# Set expander in the CA deployment command
--expander=least-waste
```

---

## Karpenter (EKS Alternative)

Karpenter is AWS's next-generation node provisioner — faster and more flexible than CA on EKS.

| Feature | Cluster Autoscaler | Karpenter |
| ------- | ------------------ | --------- |
| Node groups required | Yes | No — provisions directly |
| Scale-up time | 2–5 minutes | 30–60 seconds |
| Instance type selection | Fixed per node group | Automatic best-fit |
| Spot/on-demand mixing | Manual ASG config | Built-in |
| Consolidation | Conservative | Aggressive (bin-packing) |

```bash
# Karpenter provisioner — defines what node types it can create
apiVersion: karpenter.sh/v1alpha5
kind: Provisioner
metadata:
  name: default
spec:
  requirements:
    - key: karpenter.sh/capacity-type
      operator: In
      values: ["spot", "on-demand"]
    - key: node.kubernetes.io/instance-type
      operator: In
      values: ["m5.large", "m5.xlarge", "m5.2xlarge"]
  limits:
    resources:
      cpu: "100"
  provider:
    subnetSelector:
      karpenter.sh/discovery: advanced-k8s
    securityGroupSelector:
      karpenter.sh/discovery: advanced-k8s
  ttlSecondsAfterEmpty: 30     # terminate idle nodes after 30 seconds
```

Karpenter's `ttlSecondsAfterEmpty: 30` is far more aggressive than CA's 10-minute scale-down window.

---

## Observing Autoscaler Decisions

```bash
# CA events — scale-up and scale-down decisions
kubectl get events -n kube-system | grep cluster-autoscaler

# CA status configmap — detailed state
kubectl get configmap cluster-autoscaler-status -n kube-system -o yaml

# Node group sizes over time (GKE)
gcloud container clusters describe advanced-k8s \
  --region=us-central1 \
  --format="table(nodePools[].name,nodePools[].autoscaling)"

# Current node resource usage
kubectl describe nodes | grep -A5 "Allocated resources"
# Shows how full each node is (requests vs allocatable)

# Pending pods (CA trigger)
kubectl get pods -A --field-selector=status.phase=Pending
```

---

## Common Issues

| Issue | Symptom | Fix |
| ----- | ------- | --- |
| Pods stuck Pending, CA not scaling | CA logs: `node group at max size` | Increase `--max-nodes` limit |
| CA scales up but pods still Pending | Node ready, pods still not scheduled | Pod has `nodeSelector` or `tolerations` that new node doesn't satisfy |
| CA never scales down | Nodes stay at max | Node has a pod with `safe-to-evict: "false"`, or PDB blocks all drains |
| Scale-down breaks service | Replica count drops below safe level | Add a PDB with `minAvailable` |
| Scale-up too slow for spike traffic | Pods Pending for 3+ minutes | Pre-scale before known spikes; use Karpenter on EKS for faster provisioning |
| CA and HPA fighting | HPA scales up, CA scales down repeatedly | Ensure HPA `minReplicas` keeps pods spread across nodes so no node becomes empty |
