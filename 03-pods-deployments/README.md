# Module 3: Namespaces, Pods and Deployments

**Goal:** run your first app (nginx) on Kubernetes, scale it, watch it heal itself, and roll out a new version with zero downtime.
**Prerequisite:** the Kind cluster from Module 2. **Time:** 2 to 2.5 hours.

| File | What it creates |
| --- | --- |
| `01-namespace.yaml` | Namespace `nginx-ns` |
| `02-pod.yaml` | A single bare Pod (to see its limits) |
| `03-deployment.yaml` | Deployment with 5 nginx replicas and a rolling-update strategy |
| `04-deployment-production.yaml` | The same Deployment with resources and health probes |

---

## Part 1: Namespace

A namespace is a **logical boundary** inside a cluster. If the cluster is an office building, namespaces are its departments (HR, IT, Finance): same building, separate cupboards.

- Each namespace has its own Pods, Services and configs.
- Two objects can have the same name in different namespaces, but not in the same one.
- Deleting a namespace deletes everything inside it (great for cleanup).

Namespaces every cluster starts with:

| Namespace | Purpose |
| --- | --- |
| `default` | Used when you do not specify a namespace |
| `kube-system` | Kubernetes system Pods (API Server, CoreDNS, kube-proxy) |
| `kube-public` | Readable by everyone, rarely used |
| `kube-node-lease` | Node heartbeats |

```bash
kubectl apply -f 01-namespace.yaml && kubectl get namespaces
```

**Expected:** `nginx-ns   Active`.

The quick imperative way is `kubectl create namespace nginx-ns`, but YAML files are preferred because they can live in Git.

## Part 2: Pod

- A Pod is the **smallest deployable unit** in Kubernetes. Kubernetes never runs a container directly; it always runs it inside a Pod.
- A Pod can hold one or more containers (usually one). Containers in one Pod share an IP and `localhost`.
- A Pod is **temporary**. A bare Pod that crashes or is deleted does not come back.

| Line in `02-pod.yaml` | Meaning |
| --- | --- |
| `apiVersion: v1`, `kind: Pod` | Pod is a core (`v1`) resource |
| `metadata.name: nginx-pod` | Fixed Pod name |
| `metadata.labels.app: nginx` | A sticker on the Pod. Services and Deployments find Pods by labels |
| `containers[].image: nginx:1.27` | A pinned version tag, not `latest`, so every run gets the same image |
| `containerPort: 80` | Documents that nginx listens on 80. Exposing it is the Service's job (Module 4) |

```bash
kubectl apply -f 02-pod.yaml && kubectl get pods -n nginx-ns -o wide
```

```bash
kubectl describe pod nginx-pod -n nginx-ns | tail -10 && kubectl logs nginx-pod -n nginx-ns
```

**Expected:** `nginx-pod 1/1 Running`, and in `describe` the Events: Scheduled, Pulling, Pulled, Created, Started.

Open a shell inside the container:

```bash
kubectl exec -it nginx-pod -n nginx-ns -- bash -c "curl -s localhost | head -5"
```

**The limitation of a bare Pod:**

```bash
kubectl delete pod nginx-pod -n nginx-ns && kubectl get pods -n nginx-ns
```

**Expected:** `No resources found`. Nothing brings it back. A Deployment solves this.

## Part 3: Deployment

You tell a manager: "always keep 5 branches open, all with the same menu." If one closes, the manager opens another. In Kubernetes that manager is a **Deployment**. You declare the desired state; the Deployment maintains it.

A Deployment gives you:

1. **Replicas**: several identical Pods.
2. **Self-healing**: a deleted or crashed Pod is replaced at once.
3. **Scaling**: change replicas with one command.
4. **Rolling updates and rollback**: new versions without downtime, and a way back.

### The hierarchy: Deployment → ReplicaSet → Pods

```text
Deployment  (nginx-deployment)                 you create this; keeps version history
   └── ReplicaSet (nginx-deployment-7d9c...)   created by the Deployment; keeps "5 Pods" true
         ├── Pod (nginx-deployment-7d9c...-abcde)
         ├── Pod ...
         └── Pod ...   (5 in total)
```

Every new version creates a new ReplicaSet. The old one is kept at 0 Pods, which is what makes rollback possible.

### `03-deployment.yaml` explained

| Line | Meaning |
| --- | --- |
| `apiVersion: apps/v1` | Deployments live in the `apps` API group |
| `replicas: 5` | Keep 5 Pods running at all times |
| `selector.matchLabels.app: nginx` | "Pods with label `app: nginx` are mine" |
| `strategy.type: RollingUpdate` | Replace Pods a few at a time during an update (the default) |
| `maxSurge: 1` | During an update, at most 1 extra Pod (max 6) |
| `maxUnavailable: 1` | During an update, at least 4 Pods stay available |
| `template:` | The Pod blueprint. Every new Pod is built from it |
| `template.metadata.labels.app: nginx` | Must **exactly** match the selector, or `kubectl apply` fails with `selector does not match template labels` |

```bash
kubectl apply -f 03-deployment.yaml && kubectl get deployments,pods -n nginx-ns -o wide
```

**Expected:** `nginx-deployment 5/5`, with Pods spread across both workers (the Scheduler's work).

## Part 4: Hands-on activities

Open a second terminal and keep a live view running:

```bash
kubectl get pods -n nginx-ns -w
```

**Activity 1: self-healing.** Delete any one Pod:

```bash
kubectl delete pod -n nginx-ns $(kubectl get pods -n nginx-ns -o name | head -1 | cut -d/ -f2)
```

In terminal 2 the old Pod goes `Terminating` and a new one appears within a second. The count stays 5.

**Activity 2: scale up and down.**

```bash
kubectl scale deployment nginx-deployment --replicas=10 -n nginx-ns && kubectl get deployment nginx-deployment -n nginx-ns
```

```bash
kubectl scale deployment nginx-deployment --replicas=2 -n nginx-ns
```

> **Imperative vs declarative:** `kubectl scale` works at once, but the file still says `replicas: 5`. The next `kubectl apply -f 03-deployment.yaml` sets it back to 5. In production, change the YAML and apply it, so Git and the cluster agree. Run `kubectl apply -f 03-deployment.yaml` now to return to 5.

**Activity 3: see the ReplicaSet.**

```bash
kubectl get replicaset -n nginx-ns && kubectl get pods -n nginx-ns --show-labels
```

Each Pod name starts with the ReplicaSet name, and each Pod has a `pod-template-hash` label added by Kubernetes.

**Activity 4: the power of labels.** Change one Pod's label:

```bash
kubectl label pod $(kubectl get pods -n nginx-ns -o name | head -1 | cut -d/ -f2) app=test --overwrite -n nginx-ns && kubectl get pods -n nginx-ns --show-labels
```

Now there are 6 Pods. The relabelled Pod left the selector, so the ReplicaSet created a new one to get back to 5. Delete the orphan:

```bash
kubectl delete pod -n nginx-ns -l app=test
```

## Part 5: Rolling update and rollback

With 5 replicas, `maxSurge: 1` and `maxUnavailable: 1`, the update never runs more than 6 Pods and never fewer than 4 available.

**Step 1: roll out nginx 1.28.** Change the image in `03-deployment.yaml` to `nginx:1.28`, then:

```bash
sed -i 's/nginx:1.27/nginx:1.28/' 03-deployment.yaml && kubectl apply -f 03-deployment.yaml && kubectl rollout status deployment/nginx-deployment -n nginx-ns
```

**Expected:** `deployment "nginx-deployment" successfully rolled out`.

```bash
kubectl get replicaset -n nginx-ns && kubectl describe deployment nginx-deployment -n nginx-ns | grep Image
```

Two ReplicaSets: the new one `5 5 5`, the old one `0 0 0`.

**Step 2: record and view history.**

```bash
kubectl annotate deployment nginx-deployment kubernetes.io/change-cause="upgrade to nginx 1.28" -n nginx-ns && kubectl rollout history deployment/nginx-deployment -n nginx-ns
```

**Step 3: deploy a broken version on purpose.**

```bash
kubectl set image deployment/nginx-deployment nginx=nginx:9.99-wrong -n nginx-ns && kubectl get pods -n nginx-ns
```

New Pods are stuck in `ErrImagePull` / `ImagePullBackOff`, but at least 4 old Pods keep `Running`. `maxUnavailable` protected the app.

**Step 4: roll back.**

```bash
kubectl rollout undo deployment/nginx-deployment -n nginx-ns && kubectl rollout status deployment/nginx-deployment -n nginx-ns
```

To go to a specific revision: `kubectl rollout undo deployment/nginx-deployment --to-revision=1 -n nginx-ns`.

> `kubectl set image` and `rollout undo` change the cluster, not your file. After class, keep the right image in the YAML and apply it, so file and cluster match.

## Part 6: Resources and health checks (production habits)

`04-deployment-production.yaml` adds two things every production workload needs. They are also required by HPA and VPA in Module 11.

| Field | Meaning | If exceeded |
| --- | --- | --- |
| `requests.cpu: 50m` | Guaranteed CPU. `1000m` = 1 core, so `50m` = 5% of a core. The Scheduler uses this to pick a node | (Minimum; going above is normal) |
| `requests.memory: 64Mi` | Guaranteed RAM (`Mi` = mebibyte) | |
| `limits.cpu: 200m` | CPU ceiling | The container is throttled (slowed), not killed |
| `limits.memory: 128Mi` | RAM ceiling | The container is **OOMKilled** and restarted |

| Probe | Question it asks | On failure |
| --- | --- | --- |
| `readinessProbe` | "Is this Pod ready to receive traffic?" | Removed from Service load balancing; not restarted |
| `livenessProbe` | "Is this Pod alive or stuck?" | kubelet restarts the container |

Analogy: readiness = the shop's "OPEN" sign; liveness = the shopkeeper's pulse.

```bash
kubectl apply -f 04-deployment-production.yaml && kubectl describe pod -n nginx-ns $(kubectl get pods -n nginx-ns -o name | head -1 | cut -d/ -f2) | grep -E "Liveness|Readiness|Limits|Requests" -A2
```

**Bonus:** set the liveness `path` to `/wrong-page` and apply. nginx returns 404, the kubelet restarts the container, and the `RESTARTS` column grows. Set it back to `/` afterwards.

## Part 7: Troubleshooting, cleanup and assignment

| Status | Meaning | First command |
| --- | --- | --- |
| `Pending` | No node fits (not enough resources, or rules do not match) | `kubectl describe pod <pod> -n <ns>` → Events |
| `ContainerCreating` | Image pulling or volume attaching | Wait, then `describe` |
| `ErrImagePull` / `ImagePullBackOff` | Wrong image name/tag, or private registry | Check the image name in `describe` |
| `CrashLoopBackOff` | Container starts and crashes repeatedly | `kubectl logs <pod> -n <ns> --previous` |
| `OOMKilled` | Memory limit exceeded | `describe` → Last State; raise `limits.memory` |
| `Running` but `0/1 READY` | Readiness probe failing | `describe` → Readiness probe failed |

**Cleanup** (keep the namespace and Deployment if you continue to Module 4):

```bash
kubectl delete -f 04-deployment-production.yaml
```

**Assignment**

1. Create namespace `dev-ns` from YAML.
2. Create a Deployment `web` with image `httpd:2.4`, 3 replicas, label `app: web`, requests `cpu 50m / memory 64Mi`.
3. Delete one Pod and screenshot the self-healing.
4. Change replicas to 6 in YAML (not with a command) and apply.
5. Roll out `httpd:2.4-alpine`, show `rollout history`, then `rollout undo`.
6. Bonus: make the selector and template labels different on purpose, apply, and note the error.

Submit the YAML files and the output of `kubectl get deploy,rs,pods -n dev-ns`.
