# Storage Classes and Dynamic Provisioning

## What is a StorageClass?

A **StorageClass** is a Kubernetes resource that describes the "class" of storage available in a cluster. It allows administrators to define different tiers of storage (e.g., fast SSD, slow HDD, replicated vs. non-replicated) and lets users request storage without knowing the underlying infrastructure details.

StorageClasses enable **dynamic provisioning** — volumes are created on-demand when a PVC is submitted, without an admin manually pre-creating PersistentVolumes.

---

## Static vs. Dynamic Provisioning

| | Static | Dynamic |
| --- | --- | --- |
| **PV creation** | Admin manually creates PVs beforehand | Kubernetes creates PVs automatically when a PVC is made |
| **StorageClass** | Not required (can match by label) | Required — PVC references a StorageClass |
| **Flexibility** | Low — fixed pool of PVs | High — unlimited on-demand volumes |
| **Use case** | On-prem / legacy environments | Cloud and modern clusters |

**Static provisioning flow:**

```text
Admin creates PV → User creates PVC → Kubernetes binds PVC to PV
```

**Dynamic provisioning flow:**

```text
User creates PVC (with storageClassName) → Kubernetes calls provisioner → Provisioner creates PV + underlying storage → PVC auto-binds
```

---

## StorageClass Key Fields

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: hostpath-retain
provisioner: docker.io/hostpath       # Who creates the actual volume
reclaimPolicy: Retain                 # What happens to PV when PVC is deleted
volumeBindingMode: WaitForFirstConsumer  # When to provision
allowVolumeExpansion: true            # Whether PVC resize is allowed
parameters:                           # Provisioner-specific options
  type: gp3                           # e.g., AWS EBS volume type
```

### provisioner
The plugin that creates the actual storage. Each cloud provider ships its own:

| Environment | Provisioner |
| --- | --- |
| Docker Desktop | `docker.io/hostpath` |
| Minikube | `k8s.io/minikube-hostpath` |
| AWS EKS | `ebs.csi.aws.com` |
| GKE | `pd.csi.storage.gke.io` |
| Azure AKS | `disk.csi.azure.com` |
| Local (Rancher) | `rancher.io/local-path` |

### reclaimPolicy
What happens to the underlying storage when the PVC is deleted:

- **Delete** (default for dynamic) — PV and storage are deleted automatically
- **Retain** — PV and storage are kept; admin must manually clean up
- **Recycle** (deprecated) — basic scrub (`rm -rf`) then made available again

### volumeBindingMode
- **Immediate** — PV is provisioned as soon as the PVC is created
- **WaitForFirstConsumer** — PV is provisioned only when a Pod actually uses the PVC (important for topology-aware scheduling, e.g., same AZ as the node)

### allowVolumeExpansion
Set to `true` to allow resizing a PVC after creation. The underlying storage plugin must also support expansion.

---

## Default StorageClass

A cluster can have one default StorageClass. Any PVC that does not specify a `storageClassName` gets the default. You mark a StorageClass as default with an annotation:

```yaml
metadata:
  annotations:
    storageclass.kubernetes.io/is-default-class: "true"
```

---

## Example: Full StorageClass for Docker Desktop

```yaml
apiVersion: storage.k8s.io/v1
kind: StorageClass
metadata:
  name: hostpath-retain
provisioner: docker.io/hostpath
reclaimPolicy: Retain
volumeBindingMode: WaitForFirstConsumer
allowVolumeExpansion: true
```

---

## Key Takeaways

- StorageClass is the blueprint; PVs are instances created from it
- Dynamic provisioning removes the need to pre-create PVs
- `reclaimPolicy: Retain` is safer for databases — data survives PVC deletion
- `WaitForFirstConsumer` prevents scheduling mismatches in multi-zone clusters
- Always pin a `storageClassName` in PVCs for predictable behavior — don't rely on cluster defaults
