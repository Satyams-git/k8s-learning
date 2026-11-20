# Module 9: DaemonSet

**Goal:** run exactly one copy of a Pod on every node (or on selected nodes), the pattern used by log collectors, monitoring agents and network plugins.
**Prerequisite:** Module 3. A multi-node cluster (Kind with 2 workers). **Time:** 1 hour.

| File | What it does |
| --- | --- |
| `01-namespace.yaml` | Namespace `monitoring-ns` |
| `02-daemonset.yaml` | DaemonSet `log-agent` (busybox reading the node's `/var/log`) |
| `03-toleration-patch.yaml` | Patch: also run on the control-plane |
| `04-nodeselector-patch.yaml` | Patch: run only on nodes labelled `disk=ssd` |

---

## 1. Why DaemonSet

Some work belongs to the **node**, not to an app: collect that node's logs, export its CPU/disk metrics, configure its network. You need one agent per node, and when a new node joins, it should get an agent automatically.

| | Deployment | DaemonSet |
| --- | --- | --- |
| How many Pods | `replicas: N`, anywhere | One per (matching) node, no `replicas` field |
| New node joins | Nothing happens | A Pod is added on it automatically |
| Node removed | Pods rescheduled elsewhere | That node's Pod is removed |
| Typical use | Web apps, APIs | Log agents, monitoring agents, CNI, storage drivers |

Real DaemonSets you already run:

```bash
kubectl get ds -A
```

**Expected on Kind:** `kube-proxy` and `kindnet` in `kube-system` (on kubeadm with Calico: `kube-proxy` and `calico-node`). `DESIRED` equals the number of nodes.

Real-world examples: Fluent Bit / Fluentd / Promtail (logs), Prometheus node-exporter, Datadog agent (metrics), Calico / Cilium (network), CSI node plugins (storage).

## 2. Step 1: namespace and DaemonSet

| Line in `02-daemonset.yaml` | Meaning |
| --- | --- |
| `kind: DaemonSet` | One Pod per node; note there is **no `replicas`** |
| `updateStrategy.rollingUpdate.maxUnavailable: 1` | On update, replace one node's Pod at a time |
| `command: ... while true ...` | Every 30s print the node name and how many entries are in `/var/log` |
| `env NODE_NAME` ← `fieldRef: spec.nodeName` | **Downward API**: Kubernetes tells the Pod which node it is on |
| `requests 10m/16Mi` | Agents run on every node, so keep them tiny |
| `hostPath: /var/log` | Mount the **node's** `/var/log` folder |
| `mountPath: /host/var/log`, `readOnly: true` | Visible inside at `/host/var/log`; read-only so the agent cannot damage node files |

```bash
kubectl apply -f 01-namespace.yaml -f 02-daemonset.yaml && kubectl get ds,pods -n monitoring-ns -o wide
```

**Expected:**

```text
NAME                       DESIRED   CURRENT   READY   NODE SELECTOR
daemonset.apps/log-agent   2         2         2       <none>

NAME                  READY   STATUS    NODE
pod/log-agent-abcde   1/1     Running   demo-cluster-worker
pod/log-agent-fghij   1/1     Running   demo-cluster-worker2
```

Only **2**, not 3. The control-plane node has the taint `node-role.kubernetes.io/control-plane:NoSchedule`, so normal Pods (DaemonSet Pods too) are kept off it.

```bash
kubectl logs -n monitoring-ns -l app=log-agent --prefix
```

**Expected:** one line per Pod, each with its own node name, for example `[demo-cluster-worker] 9 entries in /var/log`.

## 3. Step 2: run on the control-plane too (toleration)

A log agent should see **all** nodes. Add a toleration for the control-plane taint (tolerations are covered fully in Module 10):

```bash
kubectl describe node -l node-role.kubernetes.io/control-plane | grep Taints
```

**Expected:** `Taints: node-role.kubernetes.io/control-plane:NoSchedule`.

```bash
kubectl patch ds log-agent -n monitoring-ns --patch-file 03-toleration-patch.yaml && kubectl get pods -n monitoring-ns -o wide -w
```

**Expected:** `DESIRED` becomes 3, and a new Pod starts on `demo-cluster-control-plane`. Ctrl+C to stop watching.

## 4. Step 3: run only on selected nodes (nodeSelector)

Say only SSD nodes need this agent. Label one worker:

```bash
NODE=$(kubectl get nodes -o name -l '!node-role.kubernetes.io/control-plane' | head -1 | cut -d/ -f2) && kubectl label node $NODE disk=ssd && kubectl get nodes -L disk
```

```bash
kubectl patch ds log-agent -n monitoring-ns --patch-file 04-nodeselector-patch.yaml && kubectl get ds,pods -n monitoring-ns -o wide
```

**Expected:** `DESIRED 1`, `NODE SELECTOR disk=ssd`, one Pod on the labelled node. The others are removed.

Now label the second worker and watch a Pod appear automatically:

```bash
kubectl label node $(kubectl get nodes -o name -l '!node-role.kubernetes.io/control-plane,!disk' | head -1 | cut -d/ -f2) disk=ssd && kubectl get pods -n monitoring-ns -o wide
```

**Expected:** `DESIRED 2`. This is exactly what happens when a new node joins the cluster.

## 5. Step 4: rolling update

```bash
kubectl set image ds/log-agent -n monitoring-ns agent=busybox:1.37 && kubectl rollout status ds/log-agent -n monitoring-ns
```

**Expected:** Pods are replaced one node at a time, then `daemon set "log-agent" successfully rolled out`. Roll back with `kubectl rollout undo ds/log-agent -n monitoring-ns`.

| `updateStrategy.type` | Behaviour |
| --- | --- |
| `RollingUpdate` (default) | Replace Pods automatically, `maxUnavailable` at a time (can also use `maxSurge`) |
| `OnDelete` | New template applies only when you delete a Pod yourself: full manual control for critical agents |

## 6. Troubleshooting

| Problem | Cause | Fix |
| --- | --- | --- |
| `DESIRED` is lower than the node count | Taints on some nodes, or a `nodeSelector`/affinity excludes them | `kubectl describe node <n> \| grep Taints`; add tolerations, check labels |
| `DESIRED 0` after nodeSelector | No node has that label | `kubectl get nodes -L disk` |
| Pod `Pending` on one node only | That node lacks CPU/memory | `kubectl describe pod`; keep agent requests small |
| `ls: /host/var/log: No such file or directory` | Wrong `mountPath` or `hostPath` | Compare the YAML with Step 1 table |

## 7. Cleanup and assignment

```bash
kubectl delete ns monitoring-ns && kubectl label nodes --all disk-
```

**Assignment**

1. Write a DaemonSet `node-info` that prints the node name and the node's hostname (`/etc/hostname` mounted from the host) every minute, running on all 3 nodes.
2. Change its `updateStrategy` to `OnDelete`, change the image, and show that nothing updates until you delete a Pod.
3. List every DaemonSet in your cluster and write one line on what each does.
4. Explain why a DaemonSet has no `replicas` field.
