# Module 10: Scheduling (nodeSelector, Affinity, Taints, Tolerations, Drain)

**Goal:** control **which node** a Pod runs on: attract Pods to nodes, keep them apart, keep nodes reserved, and safely empty a node for maintenance.
**Prerequisite:** Module 3. Kind with 1 control-plane + 2 workers. **Time:** 2 hours.

| File | What it creates |
| --- | --- |
| `01-nodeselector-pod.yaml` | Namespace `sched-ns` + Pod `ssd-pod` (nodeSelector) |
| `02-node-affinity.yaml` | `web-ssd` (required affinity) and `web-prefer` (preferred affinity) |
| `03-pod-anti-affinity.yaml` | `web-spread` (one Pod per node) |
| `04-taint-toleration.yaml` | `gpu-app` (toleration + affinity) and `normal-app` |
| `05-noexecute-pod.yaml` | `patient-pod` (NoExecute with `tolerationSeconds: 60`) |

---

## 1. How the scheduler decides

When a Pod is created without a node, **kube-scheduler** picks one in two phases:

1. **Filter:** remove nodes that cannot run the Pod (not enough CPU/memory, label mismatch, taint not tolerated, port conflict).
2. **Score:** rank the remaining nodes (spread, preferred affinity, resource balance) and pick the highest.

If no node passes the filter, the Pod stays `Pending` and `kubectl describe pod` shows why, e.g. `0/3 nodes are available: 1 node(s) had untolerated taint..., 2 node(s) didn't match Pod's node affinity/selector`.

| Tool | Direction | Strength |
| --- | --- | --- |
| `nodeSelector` | Pod → node ("I want nodes with this label") | Hard, exact match only |
| Node affinity | Pod → node | Hard (`required`) or soft (`preferred`), with operators |
| Pod affinity / anti-affinity | Pod ↔ other Pods | Place near or away from other Pods |
| Taints & tolerations | Node → Pod ("keep away unless you tolerate me") | Repel |
| cordon / drain | Admin → node | Stop new Pods / move existing Pods out |

Find your worker names first (used throughout):

```bash
W1=$(kubectl get nodes -o name -l '!node-role.kubernetes.io/control-plane' | sed -n 1p | cut -d/ -f2) && W2=$(kubectl get nodes -o name -l '!node-role.kubernetes.io/control-plane' | sed -n 2p | cut -d/ -f2) && echo "W1=$W1 W2=$W2"
```

**Expected:** `W1=demo-cluster-worker W2=demo-cluster-worker2`. Keep this terminal open (the variables live only in it).

## 2. Step 1: labels and nodeSelector

```bash
kubectl label node $W1 disktype=ssd && kubectl label node $W2 disktype=hdd && kubectl get nodes -L disktype
```

```bash
kubectl apply -f 01-nodeselector-pod.yaml && kubectl get pod ssd-pod -n sched-ns -o wide
```

**Expected:** `ssd-pod` runs on `$W1`.

Test the failure case: `kubectl run nolabel -n sched-ns --image=nginx:1.27 --overrides='{"spec":{"nodeSelector":{"disktype":"nvme"}}}'`, then `kubectl describe pod nolabel -n sched-ns | tail -3`. **Expected:** `Pending`, `didn't match Pod's node affinity/selector`. Delete it: `kubectl delete pod nolabel -n sched-ns`.

## 3. Step 2: node affinity

| Part of `02-node-affinity.yaml` | Meaning |
| --- | --- |
| `requiredDuringSchedulingIgnoredDuringExecution` | **Hard rule** at scheduling time. "IgnoredDuringExecution": if the label is removed later, running Pods stay |
| `matchExpressions: key disktype, operator In, values [ssd]` | Like nodeSelector, but with operators: `In`, `NotIn`, `Exists`, `DoesNotExist`, `Gt`, `Lt` |
| `preferredDuringSchedulingIgnoredDuringExecution` | **Soft rule**: the scheduler tries, but runs the Pod elsewhere if needed |
| `weight: 80` | 1-100; how strongly this preference adds to a node's score |

```bash
kubectl apply -f 02-node-affinity.yaml && kubectl get pods -n sched-ns -o wide -l 'app in (web-ssd,web-prefer)'
```

**Expected:** both `web-ssd` Pods on `$W1`. `web-prefer` Pods mostly on `$W2` (hdd), but a preference is not a guarantee: the scheduler's spreading score may still put one on `$W1`.

Prove "preferred" is soft: scale `web-prefer` to 8 (`kubectl scale deploy web-prefer -n sched-ns --replicas=8`). All run, none `Pending`.

## 4. Step 3: pod anti-affinity

| Part of `03-pod-anti-affinity.yaml` | Meaning |
| --- | --- |
| `podAntiAffinity.required...` | Hard rule about **other Pods** |
| `labelSelector: app: web-spread` | "Avoid Pods with this label" (its own replicas) |
| `topologyKey: kubernetes.io/hostname` | "Same place" means same node. With `topology.kubernetes.io/zone` it would mean same zone |

```bash
kubectl apply -f 03-pod-anti-affinity.yaml && kubectl get pods -n sched-ns -l app=web-spread -o wide
```

**Expected:** 2 Pods `Running` (one on each worker) and **1 `Pending`**. With 2 schedulable nodes and a hard "one per node" rule, the third has nowhere to go. `kubectl describe` shows `didn't match pod anti-affinity rules`. This is how you make sure replicas of a critical app do not all die with one node. (In production, use `preferred` or `topologySpreadConstraints` if you need more replicas than nodes.)

## 5. Step 4: taints and tolerations

A **taint** on a node says "keep away". A **toleration** on a Pod says "I can handle that taint".

```text
kubectl taint node <node> key=value:EFFECT
```

| Effect | New Pods without toleration | Pods already running |
| --- | --- | --- |
| `NoSchedule` | Not scheduled | Stay |
| `PreferNoSchedule` | Avoided if possible | Stay |
| `NoExecute` | Not scheduled | **Evicted** (unless they tolerate it, optionally for `tolerationSeconds`) |

Make `$W2` a dedicated GPU node:

```bash
kubectl taint node $W2 dedicated=gpu:NoSchedule && kubectl label node $W2 dedicated=gpu && kubectl describe node $W2 | grep Taints
```

| Part of `04-taint-toleration.yaml` | Meaning |
| --- | --- |
| `tolerations: key dedicated, Equal gpu, NoSchedule` | `gpu-app` is **allowed** on the tainted node |
| `nodeAffinity ... dedicated In [gpu]` | `gpu-app` is **required** to go there |
| `normal-app`: no toleration | Can never land on `$W2` |

> **A toleration allows, it does not attract.** With only the toleration, gpu-app Pods could still go to `$W1`. "Dedicated node" = taint (keep others out) + label & affinity (pull the right Pods in).

```bash
kubectl apply -f 04-taint-toleration.yaml && kubectl get pods -n sched-ns -o wide -l 'app in (gpu-app,normal-app)'
```

**Expected:** all `gpu-app` Pods on `$W2`; all `normal-app` Pods on `$W1`.

This is also why the control-plane runs no app Pods: it has the taint `node-role.kubernetes.io/control-plane:NoSchedule` (see Module 9).

## 6. Step 5: NoExecute and tolerationSeconds

```bash
kubectl apply -f 05-noexecute-pod.yaml && kubectl get pod patient-pod -n sched-ns -o wide
```

Taint the node `patient-pod` runs on with `NoExecute`:

```bash
PN=$(kubectl get pod patient-pod -n sched-ns -o jsonpath='{.spec.nodeName}') && kubectl taint node $PN maintenance=true:NoExecute && kubectl get pods -n sched-ns -o wide -w
```

**Expected:** Pods on `$PN` without a matching toleration are evicted **immediately** (Deployments recreate them on other nodes if possible). `patient-pod` keeps running for **60 seconds**, then it is evicted too (it is a bare Pod, so nothing recreates it). Ctrl+C after that.

Remove the taint (a trailing `-` removes it):

```bash
kubectl taint node $PN maintenance=true:NoExecute-
```

## 7. Step 6: cordon, drain, uncordon

Node maintenance (OS patch, kernel upgrade, instance resize):

| Command | Effect |
| --- | --- |
| `kubectl cordon <node>` | Mark **unschedulable**: no new Pods; running Pods stay |
| `kubectl drain <node>` | Cordon + **evict** the Pods so controllers recreate them elsewhere |
| `kubectl uncordon <node>` | Schedulable again (Pods do **not** move back on their own) |

```bash
kubectl cordon $W1 && kubectl get nodes
```

**Expected:** `$W1` shows `Ready,SchedulingDisabled`.

```bash
kubectl drain $W1 --ignore-daemonsets --delete-emptydir-data
```

| Flag | Why |
| --- | --- |
| `--ignore-daemonsets` | DaemonSet Pods (kube-proxy, kindnet) belong on every node; skip them |
| `--delete-emptydir-data` | Allow evicting Pods with `emptyDir` (that data is lost) |
| `--force` | Needed for bare Pods with no controller (`ssd-pod`); they are deleted, **not** recreated |

**Expected:** without `--force`, drain stops at `ssd-pod`: `cannot delete Pods that declare no controller`. That is a safety check. Add `--force` and run again. `web-ssd` Pods then go `Pending` (their only ssd node is drained), while `normal-app` cannot move to `$W2` (tainted) and is also `Pending`. Scheduling rules still apply during drain.

```bash
kubectl uncordon $W1 && kubectl get pods -n sched-ns -o wide
```

**Expected:** `Pending` Pods start on `$W1` again.

> In production, add a **PodDisruptionBudget** so drain never evicts too many replicas of one app at once.

## 8. Cheat sheet

| Goal | Use |
| --- | --- |
| "Run only on SSD nodes" | `nodeSelector` or required node affinity |
| "Prefer SSD, but anywhere is OK" | Preferred node affinity |
| "Keep replicas on different nodes/zones" | Pod anti-affinity or `topologySpreadConstraints` |
| "Put the cache next to the app" | Pod affinity |
| "Reserve nodes for one team / GPU work" | Taint + toleration + node affinity |
| "Evict Pods from a broken node" | `NoExecute` taint |
| "Patch a node" | cordon → drain → work → uncordon |

## 9. Troubleshooting

| Message in `kubectl describe pod` | Meaning |
| --- | --- |
| `didn't match Pod's node affinity/selector` | No node has the required label |
| `had untolerated taint {dedicated: gpu}` | Pod lacks a toleration for that taint |
| `didn't match pod anti-affinity rules` | Every node already has a conflicting Pod |
| `Insufficient cpu` / `Insufficient memory` | Requests do not fit on any node |
| `node(s) were unschedulable` | Node is cordoned |

## 10. Cleanup and assignment

```bash
kubectl delete ns sched-ns && kubectl taint node $W2 dedicated=gpu:NoSchedule- && kubectl label nodes $W1 $W2 disktype- && kubectl label node $W2 dedicated- && kubectl uncordon $W1
```

```bash
kubectl get nodes -L disktype,dedicated && kubectl describe nodes | grep Taints
```

**Expected:** no labels, and only the control-plane has a taint.

**Assignment**

1. Deploy `redis` (1 replica) and an `app` Deployment (2 replicas) with **pod affinity** so app Pods run on the same node as redis.
2. Replace `web-spread`'s anti-affinity with `topologySpreadConstraints` (`maxSkew: 1`, `whenUnsatisfiable: ScheduleAnyway`) and run 4 replicas. Compare the result.
3. Taint a node `env=prod:NoSchedule` and create a Pod with `operator: Exists` toleration. Explain the difference between `Equal` and `Exists`.
4. Create a PodDisruptionBudget (`minAvailable: 2`) for a 3-replica Deployment and drain a node. What happens?
