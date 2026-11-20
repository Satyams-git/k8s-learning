# Module 11: Autoscaling (Metrics Server, HPA, VPA)

**Goal:** let Kubernetes change the number of Pods (HPA) or the size of Pods (VPA) based on real usage, and watch it happen under load.
**Prerequisite:** Module 4 (Notes app in `notes-ns`). **Time:** 2 hours.

| File | What it creates |
| --- | --- |
| `01-hpa.yaml` | HPA `notes-hpa` (1-5 replicas, CPU target 10%) |
| `02-load-generator.yaml` | Namespace `load-ns` + Deployment `load-generator` (2 busybox Pods hitting the Notes app) |
| `03-vpa.yaml` | VPA `notes-vpa` (Recreate mode, min/max limits) |

---

## 1. Three kinds of autoscaling

| Autoscaler | Changes | Example |
| --- | --- | --- |
| **HPA** (Horizontal Pod Autoscaler) | Number of Pods (`replicas`) | 2 → 5 Pods during a sale |
| **VPA** (Vertical Pod Autoscaler) | CPU/memory `requests` (and limits) of each Pod | 100m → 300m CPU per Pod |
| **Cluster Autoscaler / Karpenter** | Number of **nodes** | Add an EC2 node when Pods are `Pending` (cloud only, not covered here) |

Analogy: a restaurant at rush hour. HPA hires more waiters. VPA gives each waiter a bigger tray. Cluster Autoscaler opens another dining hall.

Both HPA and VPA need numbers, and those come from the **Metrics Server**.

## 2. Step 1: Metrics Server

```bash
kubectl apply -f https://github.com/kubernetes-sigs/metrics-server/releases/latest/download/components.yaml
```

On Kind (and many kubeadm labs) the kubelets use self-signed certificates, so Metrics Server fails with `x509: cannot validate certificate`. Allow it for the lab:

```bash
kubectl patch deployment metrics-server -n kube-system --type=json -p='[{"op":"add","path":"/spec/template/spec/containers/0/args/-","value":"--kubelet-insecure-tls"}]' && kubectl rollout status deployment/metrics-server -n kube-system
```

> `--kubelet-insecure-tls` skips certificate checks: fine for a lab, not for production (use properly signed kubelet serving certificates there).

Wait about a minute, then:

```bash
kubectl top nodes && kubectl top pods -A
```

**Expected:** CPU (in millicores, `m`) and memory for every node and Pod. `error: Metrics API not available` means wait a bit longer, or check `kubectl logs -n kube-system deploy/metrics-server`.

## 3. Step 2: make sure the Notes app has requests

HPA percentages are calculated **against the CPU request**, not against the node and not against the limit:

```text
utilization % = actual CPU usage / CPU request × 100
```

The Notes app (Module 4) requests `100m`. If a Pod uses 25m, that is 25%. **A Pod without a CPU request cannot be scaled on CPU percentage** (HPA shows `<unknown>`).

```bash
kubectl apply -f ../04-services/02-notes-app.yaml && kubectl get deploy notes-app -n notes-ns -o jsonpath='{.spec.template.spec.containers[0].resources}'; echo
```

**Expected:** `{"limits":{"cpu":"200m","memory":"256Mi"},"requests":{"cpu":"100m","memory":"128Mi"}}`.

## 4. Step 3: create the HPA

| Line in `01-hpa.yaml` | Meaning |
| --- | --- |
| `apiVersion: autoscaling/v2` | Current HPA API (v1 only supports CPU) |
| `scaleTargetRef` | What to scale: Deployment `notes-app` |
| `minReplicas: 1`, `maxReplicas: 5` | Never below 1, never above 5 |
| `averageUtilization: 10` | Keep average CPU at 10% of the request (10m). Very low so a lab load triggers it; real apps use 60-80 |
| `behavior.scaleDown.stabilizationWindowSeconds: 60` | Wait 60s of low usage before removing Pods (default 300s), to avoid flapping |

```bash
kubectl apply -f 01-hpa.yaml && kubectl get hpa -n notes-ns
```

**Expected** (after ~30 seconds):

```text
NAME        REFERENCE              TARGETS       MINPODS   MAXPODS   REPLICAS
notes-hpa   Deployment/notes-app   cpu: 1%/10%   1         5         2
```

Replicas soon drop from 2 to 1 (usage is low, and after the 60s window it scales down to `minReplicas`).

Formula the HPA uses:

```text
desiredReplicas = ceil( currentReplicas × currentUtilization / targetUtilization )
example: ceil( 1 × 35% / 10% ) = 4
```

## 5. Step 4: generate load and watch it scale

Open a **second terminal** and watch:

```bash
kubectl get hpa notes-hpa -n notes-ns -w
```

In the first terminal start the load (2 Pods calling `notes-svc` in a tight loop through cluster DNS):

```bash
kubectl apply -f 02-load-generator.yaml && kubectl get pods -n load-ns
```

**Expected** within 1-2 minutes in the watch terminal: `TARGETS` climbs above 10% (e.g. `cpu: 48%/10%`), and `REPLICAS` grows 1 → 3 → 5.

```bash
kubectl get pods -n notes-ns -o wide && kubectl top pods -n notes-ns
```

**Expected:** up to 5 `notes-app` Pods spread across the workers.

Stop the load:

```bash
kubectl delete -f 02-load-generator.yaml
```

**Expected:** about 60s after usage drops, replicas go back down to 1. See every decision with `kubectl describe hpa notes-hpa -n notes-ns` (the `Events` section shows `New size: 5; reason: cpu resource utilization (percentage of request) above target`).

## 6. Step 5: VPA

HPA adds Pods but each Pod keeps the requests you guessed. If you guessed wrong (100m when the app needs 400m, or 1Gi when it needs 150Mi), the app is throttled or the cluster wastes money. **VPA watches real usage and recommends (or applies) right-sized requests.**

### Install VPA (not built into Kubernetes)

```bash
git clone --depth 1 https://github.com/kubernetes/autoscaler.git && cd autoscaler/vertical-pod-autoscaler && ./hack/vpa-up.sh && cd ../..
```

```bash
kubectl get pods -n kube-system | grep vpa
```

**Expected:** three Pods `Running`:

| Component | Job |
| --- | --- |
| `vpa-recommender` | Reads metrics history and computes recommendations |
| `vpa-updater` | Evicts Pods whose requests are far from the recommendation (in update modes) |
| `vpa-admission-controller` | Writes the recommended requests into new Pods as they are created |

### Update modes

| `updateMode` | What happens |
| --- | --- |
| `Off` | Only recommends; nothing changes. Safe way to start |
| `Initial` | Applies recommendations only when a Pod is created; never evicts |
| `Recreate` | Evicts running Pods when they are far off, so new Pods get the new values |
| `InPlaceOrRecreate` | Resizes running Pods in place when possible (in-place Pod resize), evicts only if needed |
| `Auto` | **Deprecated**; used to mean Recreate. Do not use in new YAML |

> Older notes mention a "RecommendOnly" mode. It does not exist: the recommend-only mode is `Off`.

### Create the VPA

| Line in `03-vpa.yaml` | Meaning |
| --- | --- |
| `targetRef` | Deployment `notes-app` |
| `updateMode: "Recreate"` | Apply by evicting and recreating Pods |
| `minAllowed 50m/64Mi`, `maxAllowed 1/512Mi` | Guard rails: never recommend outside this range |
| `controlledResources: [cpu, memory]` | Manage both |

> **Never use HPA and VPA on the same metric** (both on CPU). HPA would add Pods because CPU % is high while VPA raises the request, which lowers the %; they fight. Either delete the HPA first (we do), or let HPA scale on a different metric.

The VPA updater will not evict a Pod if it is the **only** replica (it would cause downtime). Run at least 2:

```bash
kubectl delete hpa notes-hpa -n notes-ns && kubectl scale deploy notes-app -n notes-ns --replicas=2 && kubectl apply -f 03-vpa.yaml
```

Give the recommender a few minutes (restart the load generator to make the numbers more interesting), then:

```bash
kubectl get vpa -n notes-ns && kubectl describe vpa notes-vpa -n notes-ns | sed -n '/Recommendation/,$p'
```

**Expected:**

```text
NAME        MODE       CPU   MEM       PROVIDED   AGE
notes-vpa   Recreate   50m   100Mi     True       3m

  Recommendation:
    Container Recommendations:
      Container Name:  notes-app
      Lower Bound:     ...
      Target:          cpu: 50m, memory: 100Mi
      Upper Bound:     ...
```

| Field | Meaning |
| --- | --- |
| `Target` | The value VPA will set as the request |
| `Lower Bound` / `Upper Bound` | If the current request is outside this range, the updater evicts the Pod |
| `Uncapped Target` | What VPA would recommend without your min/max |

When the updater acts, Pods are recreated and their requests change:

```bash
kubectl get pods -n notes-ns -o jsonpath='{range .items[*]}{.metadata.name}{"  "}{.spec.containers[0].resources.requests}{"\n"}{end}'
```

**Expected:** requests now match the VPA target, not the original `100m/128Mi`. Pods also get the annotation `vpaUpdates: Pod resources updated by notes-vpa`. Limits are scaled in the same ratio as the original request:limit.

## 7. HPA vs VPA

| | HPA | VPA |
| --- | --- | --- |
| Changes | Replica count | Pod requests/limits |
| Built in | Yes (needs Metrics Server) | No, separate install |
| Downtime | None | Pods restarted in Recreate mode (in-place resize avoids it when possible) |
| Best for | Stateless apps with variable traffic | Finding the right size; apps that cannot scale out |
| Together | Only on different metrics | |

## 8. Troubleshooting

| Problem | Cause | Fix |
| --- | --- | --- |
| HPA `TARGETS <unknown>` | No Metrics Server, or the Pods have no CPU request | Step 1; add `resources.requests.cpu` |
| `kubectl top` → `Metrics API not available` | Metrics Server not ready / x509 error | Apply the `--kubelet-insecure-tls` patch; wait 60s |
| HPA does not scale up | Load too low, or already at `maxReplicas` | `kubectl describe hpa`; check `kubectl top pods` |
| Scale-down is slow | Stabilization window | Default is 5 minutes; we set 60s |
| VPA `PROVIDED False` / no recommendation | Too little data yet, or recommender not running | Wait a few minutes; `kubectl logs -n kube-system deploy/vpa-recommender` |
| VPA never evicts | Only 1 replica, or mode `Off`/`Initial`, or current requests inside the bounds | Scale to 2+; check `updateMode` |
| `no matches for kind "VerticalPodAutoscaler"` | VPA CRDs not installed | Run `./hack/vpa-up.sh` |

## 9. Cleanup and assignment

```bash
kubectl delete -f 03-vpa.yaml --ignore-not-found && kubectl delete -f 02-load-generator.yaml --ignore-not-found && kubectl delete hpa notes-hpa -n notes-ns --ignore-not-found
```

Remove VPA itself: `cd autoscaler/vertical-pod-autoscaler && ./hack/vpa-down.sh`. Keep Metrics Server; it is useful everywhere.

**Assignment**

1. Create an HPA with `kubectl autoscale deployment notes-app -n notes-ns --cpu-percent=50 --min=2 --max=6` and compare with the YAML version.
2. Add a memory metric (`averageUtilization: 70`) to `notes-hpa`. When both metrics exist, which one decides?
3. Create a VPA in `Off` mode for any Deployment, run load for 10 minutes and write down the recommendation. Was your original request too high or too low?
4. Explain with numbers: a Pod requests 200m and uses 150m. What utilization does HPA see? With a target of 50% and 2 replicas, how many replicas will it want?
