# Module 8: StatefulSet

**Goal:** run a stateful app (MySQL) where every Pod has a fixed name, a fixed DNS address and its own disk, and see how that differs from a Deployment.
**Prerequisite:** Module 7 (PVC and StorageClass). **Time:** 1.5 hours.

| File | What it creates |
| --- | --- |
| `01-namespace-secret.yaml` | Namespace `stateful-ns` + Secret `mysql-secret` |
| `02-headless-service.yaml` | Headless Service `mysql-headless` |
| `03-statefulset.yaml` | StatefulSet `mysql` (3 replicas, one PVC each) |

> **Resources:** 3 MySQL Pods need about 1.2Gi of memory requests. On a small machine, change `replicas` to 2.

---

## 1. Why StatefulSet

A Deployment treats Pods as identical and replaceable ("cattle"): random names (`web-7d9f8-xk2p`), any start order, and all replicas share the same PVC if you mount one. That is perfect for stateless web apps, and wrong for databases, Kafka, Zookeeper or Elasticsearch, where each member needs its own identity and its own data ("pets").

| Feature | Deployment | StatefulSet |
| --- | --- | --- |
| Pod names | Random: `web-7d9f8-xk2p` | Ordered, fixed: `mysql-0`, `mysql-1`, `mysql-2` |
| Network identity | Only through the Service IP | Each Pod gets a stable DNS name via a headless Service |
| Storage | One PVC shared by all replicas (or none) | `volumeClaimTemplates`: **one PVC per Pod**, re-attached to the same Pod name |
| Start / stop order | All at once | In order: 0 → 1 → 2 up, 2 → 1 → 0 down (default) |
| Pod replaced | New random name, new identity | Same name, same DNS, same PVC |
| Use for | Web apps, APIs | Databases, message queues, clustered systems |

## 2. Step 1: namespace and Secret

This Secret uses `stringData` (plain text; Kubernetes encodes it). Compare with `data` in Module 6.

```bash
kubectl apply -f 01-namespace-secret.yaml && kubectl get secret -n stateful-ns
```

## 3. Step 2: headless Service

| Line in `02-headless-service.yaml` | Meaning |
| --- | --- |
| `clusterIP: None` | **Headless**: no virtual IP and no load balancing. DNS returns the Pod IPs directly |
| `selector: app: mysql` | Pods it tracks |

With `serviceName: mysql-headless` in the StatefulSet, each Pod gets a DNS record:

```text
<pod-name>.<service-name>.<namespace>.svc.cluster.local
mysql-0.mysql-headless.stateful-ns.svc.cluster.local
```

```bash
kubectl apply -f 02-headless-service.yaml && kubectl get svc -n stateful-ns
```

**Expected:** `CLUSTER-IP` shows `None`.

## 4. Step 3: the StatefulSet

| Line in `03-statefulset.yaml` | Meaning |
| --- | --- |
| `kind: StatefulSet` | Ordered, stable Pods |
| `serviceName: mysql-headless` | The headless Service that provides Pod DNS names (must exist) |
| `replicas: 3` | Pods `mysql-0`, `mysql-1`, `mysql-2` |
| `resources` requests 100m/384Mi, limit 768Mi | Small enough for a Kind laptop cluster |
| `volumeClaimTemplates` | A PVC **template**: the controller creates `mysql-storage-mysql-0`, `-1`, `-2` |
| `storageClassName: standard` | Kind's default StorageClass (dynamic provisioning, Module 7) |

```bash
kubectl apply -f 03-statefulset.yaml && kubectl get pods -n stateful-ns -w
```

**Expected:** Pods appear **one at a time**. `mysql-1` is created only after `mysql-0` is `Running` and Ready, then `mysql-2`. Press Ctrl+C when all 3 are `1/1 Running`.

```bash
kubectl get sts,pvc -n stateful-ns
```

**Expected:**

```text
NAME                     READY   AGE
statefulset.apps/mysql   3/3     2m

NAME                                          STATUS   VOLUME        CAPACITY   STORAGECLASS
persistentvolumeclaim/mysql-storage-mysql-0   Bound    pvc-...       500Mi      standard
persistentvolumeclaim/mysql-storage-mysql-1   Bound    pvc-...       500Mi      standard
persistentvolumeclaim/mysql-storage-mysql-2   Bound    pvc-...       500Mi      standard
```

PVC name = `<template-name>-<pod-name>`.

## 5. Step 4: stable DNS

```bash
kubectl run dns-test -n stateful-ns --image=busybox:1.36 --rm -it --restart=Never -- nslookup mysql-0.mysql-headless
```

**Expected:** one IP, the IP of Pod `mysql-0`.

```bash
kubectl run dns-test -n stateful-ns --image=busybox:1.36 --rm -it --restart=Never -- nslookup mysql-headless
```

**Expected:** three IPs, one per Pod (a normal Service would return one virtual IP).

## 6. Step 5: identity and data stay with the Pod name

Write a different value into each Pod:

```bash
for i in 0 1 2; do kubectl exec -n stateful-ns mysql-$i -- mysql -uroot -pAdmin123 -e "CREATE DATABASE IF NOT EXISTS demo; CREATE TABLE IF NOT EXISTS demo.who (name VARCHAR(20)); INSERT INTO demo.who VALUES ('I am mysql-$i');"; done
```

Note `mysql-1`'s IP, then delete it:

```bash
kubectl get pod mysql-1 -n stateful-ns -o wide && kubectl delete pod mysql-1 -n stateful-ns && kubectl wait --for=condition=Ready pod/mysql-1 -n stateful-ns --timeout=180s
```

```bash
kubectl get pod mysql-1 -n stateful-ns -o wide && kubectl exec -n stateful-ns mysql-1 -- mysql -uroot -pAdmin123 -e "SELECT * FROM demo.who;"
```

**Expected:** the new Pod has the **same name** `mysql-1` (the IP may change, the DNS name does not), and the table still says `I am mysql-1`: it re-attached to `mysql-storage-mysql-1`.

## 7. Correction: a StatefulSet does not replicate data

Check `mysql-0`:

```bash
kubectl exec -n stateful-ns mysql-0 -- mysql -uroot -pAdmin123 -e "SELECT * FROM demo.who;"
```

**Expected:** only `I am mysql-0`. The three Pods are **three independent MySQL servers**, each with its own disk. A StatefulSet gives identity, order and storage; it does **not** copy data between Pods. Real replication (primary/replica, Group Replication) is configured inside the database, usually by an **Operator** (MySQL Operator, Percona, CloudNativePG for Postgres) or a Helm chart that sets it up.

## 8. Scaling and other settings

```bash
kubectl scale sts mysql -n stateful-ns --replicas=2 && kubectl get pods,pvc -n stateful-ns
```

**Expected:** `mysql-2` is removed (highest number first), but **PVC `mysql-storage-mysql-2` stays**. Scale back to 3 and `mysql-2` gets its old data back.

| Setting | Values | Meaning |
| --- | --- | --- |
| `podManagementPolicy` | `OrderedReady` (default) / `Parallel` | `Parallel` starts/stops all Pods at once, when order does not matter |
| `updateStrategy.type` | `RollingUpdate` (default) / `OnDelete` | RollingUpdate replaces Pods in reverse order (2 → 1 → 0); OnDelete waits until you delete each Pod |
| `updateStrategy.rollingUpdate.partition` | e.g. `2` | Only Pods with ordinal ≥ 2 are updated: a canary for StatefulSets |
| `persistentVolumeClaimRetentionPolicy` | `whenDeleted` / `whenScaled`: `Retain` (default) or `Delete` | Whether PVCs are removed when the StatefulSet is deleted or scaled down |

Example canary: `kubectl patch sts mysql -n stateful-ns -p '{"spec":{"updateStrategy":{"rollingUpdate":{"partition":2}}}}'`, then change the image; only `mysql-2` updates.

## 9. Troubleshooting

| Problem | Cause | Fix |
| --- | --- | --- |
| Only `mysql-0` exists, stuck | `mysql-0` is not Ready, so OrderedReady waits | `kubectl describe pod mysql-0` / `kubectl logs mysql-0` |
| Pod `Pending`, `Insufficient memory` | 3 × 384Mi requests do not fit | Lower replicas to 2 |
| PVCs `Pending` | Wrong `storageClassName` | Use the name from `kubectl get sc` |
| `nslookup mysql-0.mysql-headless` fails | `serviceName` does not match the Service name, or the Service is not headless | Both must be `mysql-headless`, with `clusterIP: None` |
| Old data after deleting and recreating the StatefulSet | PVCs are retained by default | Delete the PVCs explicitly if you want a fresh start |

## 10. Cleanup and assignment

Deleting the StatefulSet does **not** delete its PVCs. Delete both:

```bash
kubectl delete -f 03-statefulset.yaml -f 02-headless-service.yaml && kubectl delete pvc -n stateful-ns -l app=mysql && kubectl delete ns stateful-ns
```

**Assignment**

1. Create a StatefulSet `web` with 3 nginx Pods, a headless Service, and a 100Mi `volumeClaimTemplate` mounted at `/usr/share/nginx/html`. Write the Pod name into each `index.html` and curl each Pod by its DNS name.
2. Change `podManagementPolicy` to `Parallel` and compare the start order.
3. Use `partition` to update only the last Pod to a new image.
4. Explain: why does a database need a StatefulSet and not a Deployment? Why is a StatefulSet alone not a replicated database?
