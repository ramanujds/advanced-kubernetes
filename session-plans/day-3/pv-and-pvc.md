# Persistent Volumes (PV) and Persistent Volume Claims (PVC)

## Overview

Kubernetes decouples storage from Pods using two objects:

- **PersistentVolume (PV)** — a piece of storage in the cluster, provisioned by an admin or dynamically by a StorageClass. It exists independently of any Pod.
- **PersistentVolumeClaim (PVC)** — a request for storage by a user. A PVC binds to a matching PV, and a Pod mounts the PVC as a volume.

This separation means Pods don't care *where* the storage is — they just request what they need.

---

## PV and PVC Lifecycle

```text
Provisioning → Binding → Using → Releasing → Reclaiming
```

1. **Provisioning** — PV is created (manually by admin, or dynamically via StorageClass)
2. **Binding** — Kubernetes matches the PVC to a suitable PV (capacity, access mode, storageClass)
3. **Using** — Pod mounts the PVC; reads/writes happen on the underlying storage
4. **Releasing** — PVC is deleted; PV status becomes `Released`
5. **Reclaiming** — PV is handled according to its `reclaimPolicy` (Retain / Delete)

---

## PersistentVolume (PV)

A PV describes actual storage: path on a node, a cloud disk, an NFS share, etc.

```yaml
apiVersion: v1
kind: PersistentVolume
metadata:
  name: mysql-pv
spec:
  capacity:
    storage: 5Gi
  accessModes:
    - ReadWriteOnce
  reclaimPolicy: Retain
  storageClassName: hostpath-retain
  hostPath:
    path: /data/mysql        # actual directory on the node
```

### Key fields

| Field | Purpose |
| --- | --- |
| `capacity.storage` | Size of the volume |
| `accessModes` | How the volume can be mounted |
| `reclaimPolicy` | What to do when PVC is deleted |
| `storageClassName` | Links PV to a StorageClass (for binding) |
| `hostPath / nfs / awsElasticBlockStore / ...` | The actual storage backend |

---

## PersistentVolumeClaim (PVC)

A PVC is a request: "I need 1Gi of storage with ReadWriteOnce access."

```yaml
apiVersion: v1
kind: PersistentVolumeClaim
metadata:
  name: mysql-pvc
spec:
  accessModes:
    - ReadWriteOnce
  storageClassName: hostpath-retain   # must match the StorageClass / PV
  resources:
    requests:
      storage: 1Gi
```

Kubernetes finds a PV that satisfies all constraints (storage >= request, matching accessMode and storageClassName) and binds them together. Once bound, no other PVC can claim that PV.

---

## Access Modes

| Mode | Short | Meaning |
| --- | --- | --- |
| `ReadWriteOnce` | RWO | Mounted read-write by **one node** at a time |
| `ReadOnlyMany` | ROX | Mounted read-only by **many nodes** simultaneously |
| `ReadWriteMany` | RWX | Mounted read-write by **many nodes** simultaneously |
| `ReadWriteOncePod` | RWOP | Mounted read-write by **one Pod** only (Kubernetes 1.22+) |

> **Important:** Most block storage backends (AWS EBS, Azure Disk, GCP PD) only support `ReadWriteOnce`. `ReadWriteMany` requires a shared filesystem like NFS or cloud file storage.

For MySQL, always use **ReadWriteOnce** — only one MySQL instance should write to its data directory at a time.

---

## Reclaim Policies

| Policy | Effect after PVC deletion |
| --- | --- |
| `Delete` | PV and underlying storage are deleted automatically |
| `Retain` | PV stays, status becomes `Released`; admin must reclaim manually |
| `Recycle` | *(Deprecated)* Basic scrub of the volume, then made `Available` again |

Use `Retain` for databases and anything where data must survive accidental PVC deletion.

---

## Mounting a PVC in a Pod

```yaml
spec:
  containers:
    - name: mysql
      image: mysql:8.0
      volumeMounts:
        - name: mysql-data
          mountPath: /var/lib/mysql
  volumes:
    - name: mysql-data
      persistentVolumeClaim:
        claimName: mysql-pvc       # references the PVC by name
```

---

## Checking PV / PVC Status

```bash
kubectl get pv
kubectl get pvc
kubectl describe pvc mysql-pvc
```

PVC status values:

- **Pending** — no matching PV found yet (or waiting for `WaitForFirstConsumer`)
- **Bound** — successfully matched and bound to a PV
- **Lost** — the backing PV was deleted while the PVC was bound

---

## Static vs. Dynamic Provisioning Summary

### Static (admin pre-creates PVs)

```bash
Admin: kubectl apply -f pv.yaml
User:  kubectl apply -f pvc.yaml   # Kubernetes auto-binds to the pre-existing PV
```

### Dynamic (StorageClass does it automatically)

```bash
User: kubectl apply -f pvc.yaml    # StorageClass creates PV + storage on the fly
```

Dynamic provisioning requires the PVC to reference a StorageClass with a provisioner installed in the cluster.

---

## Key Takeaways

- PV = the actual storage resource; PVC = the claim/request for storage
- A PVC binds to exactly one PV; binding is exclusive
- Always specify `storageClassName` — relying on the cluster default is fragile
- Use `reclaimPolicy: Retain` for stateful workloads like databases
- For MySQL (and any single-writer DB), always use `ReadWriteOnce`
