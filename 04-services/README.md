# Module 4: Services (ClusterIP, NodePort, LoadBalancer)

**Goal:** put a stable name and IP in front of Pods, and open an app in the browser.
**Prerequisite:** Module 3's `nginx-deployment` in `nginx-ns`. **Time:** 1.5 hours.

| File | What it creates |
| --- | --- |
| `01-service-clusterip.yaml` | ClusterIP Service `nginx-svc` (port 82 → Pod port 80) |
| `02-notes-app.yaml` | Namespace `notes-ns`, Notes App Deployment (2 replicas), NodePort Service `notes-svc` on 30080 |

---

## 1. Why Services exist

**Problem: Pod IPs are not permanent.** When a Pod is deleted, crashes or is updated, the new Pod gets a **new IP**. If a backend hard-codes a frontend Pod's IP, every restart breaks the connection. And with 5 replicas, which IP would you even call?

**Solution: a Service.** A Service gives Pods a **stable IP and DNS name**, and load-balances traffic across all matching Pods. Pods come and go; the Service name and IP stay the same.

Analogy: a company's customer care number never changes, even though the agent who answers changes every day. Service = the fixed number; Pods = the agents.

A Service finds its Pods by **label selector** (Module 3). The ready Pods that match form its **endpoints** (EndpointSlice).

| Type | Reachable from | Use when |
| --- | --- | --- |
| `ClusterIP` (default) | Inside the cluster only | Internal traffic: frontend → backend, app → database |
| `NodePort` | Every node's IP on a fixed port (30000-32767) | Labs (Kind, kubeadm), simple outside access |
| `LoadBalancer` | A cloud load balancer with a public IP/DNS | Production on EKS / AKS / GKE |
| `ExternalName` | A DNS alias inside the cluster to an outside name | Calling an external database or API by an internal name |
| Headless (`clusterIP: None`) | No virtual IP; DNS returns each Pod's IP | StatefulSets (Module 8) |

Each type builds on the previous one: a NodePort also has a ClusterIP, and a LoadBalancer also has a NodePort and a ClusterIP.

## 2. Lab A: ClusterIP for nginx

Make sure Module 3's Deployment is running:

```bash
kubectl get deploy,pods -n nginx-ns
```

If not: `kubectl apply -f ../03-pods-deployments/01-namespace.yaml -f ../03-pods-deployments/03-deployment.yaml`.

| Line in `01-service-clusterip.yaml` | Meaning |
| --- | --- |
| `name: nginx-svc` | The DNS name will be `nginx-svc` |
| `namespace: nginx-ns` | Service and Pods must be in the same namespace |
| `type: ClusterIP` | Internal only (the default) |
| `selector.app: nginx` | Send traffic to Pods labelled `app: nginx` (the 5 Pods from Module 3) |
| `port: 82` | **The Service's port.** Clients call `nginx-svc:82` |
| `targetPort: 80` | **The Pod's port.** nginx listens on 80 |

```bash
kubectl apply -f 01-service-clusterip.yaml && kubectl get svc,endpointslices -n nginx-ns
```

**Expected:** `nginx-svc ClusterIP 10.96.x.x <none> 82/TCP`, and 5 Pod IPs in the EndpointSlice. **Empty endpoints almost always mean the selector does not match the Pod labels.**

### Test from inside the cluster

A ClusterIP is not reachable from outside, so send the request from a temporary Pod:

```bash
kubectl run tmp-client --rm -it --image=busybox:1.36 -n nginx-ns -- wget -qO- http://nginx-svc:82
```

**Expected:** the "Welcome to nginx!" HTML. `--rm` deletes the temporary Pod when it exits.

### See load balancing live

Write each Pod's name into its own page, then call the Service 8 times:

```bash
for p in $(kubectl get pods -n nginx-ns -l app=nginx -o name); do kubectl exec -n nginx-ns $p -- sh -c 'echo "Served by $(hostname)" > /usr/share/nginx/html/index.html'; done
```

```bash
kubectl run tmp-client --rm -it --image=busybox:1.36 -n nginx-ns -- sh -c 'for i in 1 2 3 4 5 6 7 8; do wget -qO- http://nginx-svc:82; done'
```

**Expected:** different Pod names. That is kube-proxy load balancing. (This change lives inside the containers; a Pod restart restores the default page.)

## 3. Service DNS and port-forward

CoreDNS gives every Service a name:

```text
<service-name>.<namespace>.svc.cluster.local
nginx-svc.nginx-ns.svc.cluster.local
```

| Client is in | Name that works |
| --- | --- |
| The same namespace (`nginx-ns`) | `nginx-svc` |
| Another namespace | `nginx-svc.nginx-ns` or the full name |

Module 11's load generator uses exactly this: `http://notes-svc.notes-ns.svc.cluster.local:82`.

**port-forward: a temporary path from your machine to a ClusterIP**

```bash
kubectl port-forward svc/nginx-svc -n nginx-ns 8080:82 --address=0.0.0.0
```

| Part | Meaning |
| --- | --- |
| `svc/nginx-svc` | Which Service to reach |
| `8080:82` | `local-port:service-port` (machine 8080 → Service 82) |
| `--address=0.0.0.0` | Also listen on the EC2 public IP (default is `localhost` only) |

Open `http://<EC2-PUBLIC-IP>:8080` (allow 8080 in the Security Group). The command must keep running; `Ctrl+C` stops it.

> port-forward is for debugging and demos, not production. Keep local ports at 8080 or above: ports below 1024 need root.

## 4. Lab B: Notes App on a NodePort

`satyamsri/notes-app` is a PHP + Apache app on port 80 that writes notes to `/data`. **This file is reused in Modules 11 and 12**, so keep it.

New lines compared with Module 3:

| Line | Meaning |
| --- | --- |
| `---` | Separates several objects in one file (this file has 3) |
| `volumeMounts` + `volumes.emptyDir` | A temporary folder at `/data`. Pod deleted = data deleted (persistent storage comes in Module 7) |
| `resources` | Requests/limits; needed for HPA/VPA in Module 11 |
| `type: NodePort` | Open a port on every node |
| `port: 82` | The Service port inside the cluster (`notes-svc:82`) |
| `targetPort: 80` | The container port (Apache) |
| `nodePort: 30080` | The node port, range 30000-32767. Leave it out and Kubernetes picks a random one |

**Traffic path on Kind:**

```text
Browser → EC2-public-IP:30080
        → Kind control-plane container :30080   (extraPortMappings in cluster.yml)
        → notes-svc  (NodePort 30080 → port 82)
        → notes-app Pod :80   (targetPort)
```

```bash
kubectl apply -f 02-notes-app.yaml && kubectl get all -n notes-ns
```

**Expected:** `service/notes-svc NodePort 10.96.x.x <none> 82:30080/TCP`. Read `82:30080` as: Service port 82, NodePort 30080.

```bash
curl -s http://localhost:30080 | head -5
```

Then open `http://<EC2-PUBLIC-IP>:30080` (allow 30080 in the Security Group) and save a note.

> **Think about it:** there are 2 replicas, each with its own `emptyDir`. Save a note and refresh a few times: sometimes the note is there, sometimes not. Why? Requests are load-balanced across Pods, and each Pod has separate storage. Shared persistent storage comes in Module 7.

## 5. LoadBalancer, troubleshooting and assignment

On a cloud cluster (EKS, AKS, GKE), `type: LoadBalancer` makes the provider create a real load balancer, and its public IP/DNS appears in `EXTERNAL-IP`.

On Kind or plain kubeadm there is no cloud integration, so `EXTERNAL-IP` stays `<pending>`. That is expected, not an error. Use NodePort or port-forward instead.

```bash
kubectl expose deployment nginx-deployment --name=nginx-lb --type=LoadBalancer --port=80 -n nginx-ns && kubectl get svc nginx-lb -n nginx-ns
```

```bash
kubectl delete svc nginx-lb -n nginx-ns
```

| Problem | Check | Fix |
| --- | --- | --- |
| Service gives no response | `kubectl get endpointslices -n <ns>` empty? | Match the Service `selector` to the Pod labels (`kubectl get pods --show-labels`) |
| `connection refused` | Does `targetPort` match the container port? | 80 for nginx and notes-app |
| NodePort not opening in the browser | Does `curl localhost:30080` work on the EC2? | Yes → open 30080 in the Security Group. No → check `extraPortMappings` |
| `provided port is already allocated` | Another Service uses that nodePort | Pick another (30081) |
| `provided port is not in the valid range` | nodePort outside 30000-32767 | Use a port in range |
| `EXTERNAL-IP <pending>` on Kind | No cloud load balancer | Expected; use NodePort/port-forward |

**Cleanup** (keep `02-notes-app.yaml` running if you go on to Module 11):

```bash
kubectl delete -f 01-service-clusterip.yaml
```

**Assignment**

1. Create a ClusterIP Service for Module 3's `web` (httpd) Deployment: port 8080 → targetPort 80.
2. From a busybox Pod, run `wget -qO- http://web-svc.dev-ns:8080`.
3. Create a NodePort 30081 Service for the same app and open it in the browser.
4. Break the selector on purpose, check the endpoints, and note the symptom.
5. In one line each: the difference between ClusterIP, NodePort and LoadBalancer.
