# Module 7: Storage (PersistentVolume, PersistentVolumeClaim, StorageClass)

**Goal:** fix Module 6's data-loss problem. Give MySQL a PersistentVolume so data survives Pod deletion, then let a StorageClass create volumes automatically.
**Prerequisite:** Module 6 (namespace `mysql`, `mysql-secret`, `mysql-config` must exist). **Time:** 1.5 hours.

| File | What it creates |
| --- | --- |
| `01-pv.yaml` | Static PV `mysql-pv` (2Gi, hostPath on a labelled node) |
| `02-pvc.yaml` | PVC `mysql-pvc` that claims it |
| `03-mysql-with-pvc.yaml` | MySQL Deployment with the PVC mounted at `/var/lib/mysql` + Service |
| `04-dynamic-pvc.yaml` | PVC on StorageClass `standard` + a `writer` Pod |

---

## 1. Concepts

| Object | Who creates it | What it is | Analogy |
| --- | --- | --- | --- |
| **PersistentVolume (PV)** | Admin (static) or a provisioner (dynamic) | A piece of real storage: disk, folder, EBS, NFS. Cluster-wide (no namespace) | A flat available for rent |
| **PersistentVolumeClaim (PVC)** | Developer | A request: "I need 2Gi, ReadWriteOnce". Namespaced | A rental application |
| **StorageClass** | Admin | A template that creates PVs on demand | A builder who constructs a flat when you apply |

The Pod never talks to the PV directly: **Pod → PVC → PV → real storage**. This keeps the app YAML the same whether the storage is a local folder, AWS EBS or NFS.

### Access modes

| Mode | Short | Meaning |
| --- | --- | --- |
| ReadWriteOnce | RWO | Read-write by Pods on **one node** |
| ReadOnlyMany | ROX | Read-only by many nodes |
| ReadWriteMany | RWX | Read-write by many nodes (needs NFS, EFS, CephFS...) |
| ReadWriteOncePod | RWOP | Read-write by exactly **one Pod** |

### Reclaim policy (what happens to the PV when the PVC is deleted)

| Policy | Effect |
| --- | --- |
| `Retain` | PV and data stay; PV becomes `Released`, an admin must clean it up manually |
| `Delete` | PV and the backing storage are deleted (default for dynamic PVs) |

### PV lifecycle

`Available` (free) → `Bound` (claimed by a PVC) → `Released` (PVC deleted, Retain policy) → manually cleaned or deleted.

## 2. Part A: static provisioning

### Step 1: pick and label a worker node

`hostPath` storage is a folder on one specific node. If the Pod moves to another node, it would see an empty folder. So the PV says "I live on the node labelled `storage=local`", and the scheduler places the Pod there.

```bash
NODE=$(kubectl get nodes -o name -l '!node-role.kubernetes.io/control-plane' | head -1 | cut -d/ -f2) && kubectl label node $NODE storage=local && kubectl get nodes -L storage
```

**Expected:** one worker (for example `demo-cluster-worker`) shows `local` in the `STORAGE` column.

### Step 2: create the PV

| Line in `01-pv.yaml` | Meaning |
| --- | --- |
| `capacity.storage: 2Gi` | Size this PV offers |
| `accessModes: [ReadWriteOnce]` | One node at a time |
| `persistentVolumeReclaimPolicy: Retain` | Keep the data even if the PVC is deleted |
| `storageClassName: manual` | A name used only for matching; PVCs asking for `manual` bind here. It does not need a StorageClass object |
| `hostPath.path: /mnt/data/mysql` | Folder on the node (on Kind, inside the node container) |
| `type: DirectoryOrCreate` | Create the folder if missing |
| `nodeAffinity ... storage In [local]` | The PV exists only on the labelled node |

```bash
kubectl apply -f 01-pv.yaml && kubectl get pv
```

**Expected:** `mysql-pv   2Gi   RWO   Retain   Available   manual`.

### Step 3: create the PVC

Binding rules: same `storageClassName`, a compatible access mode, and capacity ≥ request.

```bash
kubectl apply -f 02-pvc.yaml && kubectl get pvc -n mysql && kubectl get pv
```

**Expected:** PVC `mysql-pvc   Bound   mysql-pv   2Gi`, and the PV status is now `Bound` with `CLAIM mysql/mysql-pvc`.

### Step 4: MySQL with the PVC

| New lines in `03-mysql-with-pvc.yaml` | Meaning |
| --- | --- |
| `strategy.type: Recreate` | Stop the old Pod **before** starting the new one. With RollingUpdate, two MySQL processes could open the same data folder and corrupt it, and an RWO volume cannot attach to two Pods on different nodes anyway |
| `volumes.persistentVolumeClaim.claimName: mysql-pvc` | Use the claim |
| `volumeMounts.mountPath: /var/lib/mysql` | MySQL's data directory now lives on the PV |

```bash
kubectl apply -f 03-mysql-with-pvc.yaml && kubectl get pods -n mysql -o wide -w
```

Wait for `1/1 Running`. The `NODE` column must show the labelled node.

### Step 5: persistence test

```bash
kubectl exec -it -n mysql deploy/mysql-dep -- mysql -u root -pAdmin123 -e "CREATE TABLE myDB.students (id INT PRIMARY KEY, name VARCHAR(50)); INSERT INTO myDB.students VALUES (1,'Aman'),(2,'Priya'); SELECT * FROM myDB.students;"
```

Delete the Pod and wait for the new one:

```bash
kubectl delete pod -n mysql -l app=mysql && kubectl wait --for=condition=Ready pod -l app=mysql -n mysql --timeout=180s
```

```bash
kubectl exec -it -n mysql deploy/mysql-dep -- mysql -u root -pAdmin123 -e "SELECT * FROM myDB.students;"
```

**Expected:** both rows (`Aman`, `Priya`) are still there. Data survived because it lives on the PV, not inside the container.

Look at the files on the node (Kind nodes are Docker containers):

```bash
docker exec $NODE ls /mnt/data/mysql
```

**Expected:** MySQL files such as `ibdata1`, `mysql.ibd`, and a `myDB` folder. (On a kubeadm/VM cluster, SSH to the node and run `ls /mnt/data/mysql`.)

## 3. Part B: dynamic provisioning

Writing a PV for every app does not scale. A **StorageClass** creates PVs automatically when a PVC asks.

```bash
kubectl get storageclass
```

**Expected on Kind:** `standard (default)   rancher.io/local-path   Delete   WaitForFirstConsumer`.

| Column | Meaning |
| --- | --- |
| `PROVISIONER` | The program that creates volumes (here local-path; on AWS `ebs.csi.aws.com`) |
| `RECLAIMPOLICY: Delete` | Dynamic PVs are deleted with their PVC |
| `VOLUMEBINDINGMODE: WaitForFirstConsumer` | Do not create the volume until a Pod uses the PVC, so it is created on the node where that Pod runs |

> On Kind the class is named `standard`. The same provisioner installed by hand (Rancher's local-path-provisioner) is named `local-path`, and on EKS it is usually `gp3`/`gp2`. Use the name `kubectl get storageclass` shows.

```bash
kubectl apply -f 04-dynamic-pvc.yaml && kubectl get pvc dynamic-pvc -n mysql && kubectl get pv
```

**Expected:** the PVC goes `Pending` → `Bound` once the `writer` Pod is scheduled, and a new PV named `pvc-<uuid>` appears with `STORAGECLASS standard`. You never wrote that PV.

```bash
kubectl exec -n mysql writer -- cat /data/log.txt
```

**Expected:** a date line.

## 4. Two mistakes in older notes

> **Adding `fsGroup` to fix hostPath permissions.** `fsGroup` changes ownership only for volume types that support it; it does nothing for `hostPath`. The official MySQL image already starts as root and fixes `/var/lib/mysql` ownership itself, so no `securityContext` is needed for this lab.

> **`kubectl delete pv --all` for cleanup.** This deletes every PV in the cluster, including volumes of other teams and apps. Always delete by name.

## 5. Troubleshooting

| Problem | Cause | Fix |
| --- | --- | --- |
| PVC stuck `Pending` (static) | No PV matches: different `storageClassName`, access mode, or PV smaller than the request | `kubectl describe pvc mysql-pvc -n mysql`; compare with `kubectl get pv` |
| PVC `Pending` (dynamic), event `waiting for first consumer` | Normal with `WaitForFirstConsumer`: create the Pod | Apply the Pod |
| Pod `Pending`, `didn't match PersistentVolume's node affinity` | No node has the `storage=local` label | Run Step 1 |
| PV `Released`, new PVC will not bind | `Retain` PVs keep the old `claimRef` | Delete and recreate the PV (data folder stays), or `kubectl patch pv mysql-pv -p '{"spec":{"claimRef":null}}'` |
| MySQL `CrashLoopBackOff`, logs show password errors | Data folder was initialised earlier with another password | Clean `/mnt/data/mysql` on the node, then recreate the Pod |
| PVC stuck `Terminating` | A Pod still uses it (protection finalizer) | Delete the Pod first |

## 6. Cleanup and assignment

```bash
kubectl delete -f 04-dynamic-pvc.yaml -f 03-mysql-with-pvc.yaml -f 02-pvc.yaml && kubectl delete pv mysql-pv && kubectl label node $NODE storage-
```

```bash
docker exec $NODE rm -rf /mnt/data/mysql
```

Keep or delete the namespace: `kubectl delete ns mysql` removes the Secret and ConfigMap too.

**Assignment**

1. Delete only the PVC `mysql-pvc` (Retain policy). What is the PV status? Is the data still in `/mnt/data/mysql`? Re-bind it.
2. Repeat the persistence test with `dynamic-pvc` instead of the static PV.
3. Create a PVC asking for `ReadWriteMany` on `standard`. What happens and why?
4. Explain in your own words why MySQL uses `strategy: Recreate`.
