# Module 1: From Docker to Kubernetes (Theory and Architecture)

**Goal:** understand why the industry needs Kubernetes on top of Docker, and what each part of a cluster does.
**Time:** about 2 hours (theory only, no lab).

---

## 1. Why Docker alone is not enough

Docker builds and runs containers. That is enough for a small team with one or two apps on one server. A company running hundreds of containers for millions of users hits five problems:

| Problem | What happens with Docker alone | What the business needs | Kubernetes answer |
| --- | --- | --- | --- |
| Scaling | Traffic doubles, you run more `docker run` commands by hand | Scale up and down automatically | Deployment replicas + HPA |
| Load balancing | Each container has its own IP; one is overloaded, others idle | Spread traffic evenly | Service (built-in load balancing) |
| Self-healing | A crashed container stays down until someone restarts it | Replace failed containers automatically | Controllers keep the desired state |
| Monitoring and logging | `docker logs` shows one container at a time | One view of the health of everything | Metrics Server, Prometheus, Grafana |
| Multi-host | Containers on different servers cannot easily talk | Run across many servers and regions | Cluster networking (CNI), service discovery |

**Real scenario: a festival sale.** On a normal day an e-commerce site runs about 200 containers. The sale starts, traffic grows 5x, and some containers crash under load. With Docker alone, no new containers start, some containers are overloaded while others sit idle, and crashed containers do not come back. The site slows down and checkouts fail. Filling this gap is called **container orchestration**, and Kubernetes is the industry-standard orchestrator.

## 2. What Kubernetes is

Kubernetes (K8s) is an open-source **container orchestration platform**. It:

- keeps containers healthy and running,
- scales them up when demand grows and down when it drops,
- replaces crashed containers automatically (self-healing),
- spreads traffic across containers (load balancing),
- rolls out new versions without downtime, and rolls back when needed.

Google built Kubernetes from its experience with an internal system called Borg and open-sourced it in 2014. It is now maintained by the **CNCF (Cloud Native Computing Foundation)**.

### CNCF project stages

| Stage | Meaning | Examples |
| --- | --- | --- |
| Sandbox | New, experimental | New monitoring or security tools |
| Incubating | Growing community, used in some production setups | Projects on the way to graduation |
| Graduated | Stable, widely adopted, trusted | Kubernetes, containerd, Prometheus, Helm, Argo |

> **Common mistake:** "Docker and Kubernetes are both CNCF graduated projects." Docker is not a CNCF project. Docker donated its container runtime **containerd** to the CNCF, and containerd is graduated.

### Docker and Kubernetes work together

They are not competitors. Docker builds images. Kubernetes runs containers from those images across a cluster. Kubernetes itself uses a container runtime (usually containerd) to start containers. Since Kubernetes 1.24 the kubelet no longer talks to Docker Engine directly ("dockershim" was removed), but images built with Docker still work, because both follow the same OCI image format.

## 3. Control plane: the brain of the cluster

A cluster has two parts: the **control plane** (makes decisions) and **worker nodes** (do the work).

| Component | Job | Analogy |
| --- | --- | --- |
| API Server (`kube-apiserver`) | Entry point of the cluster. Every request (kubectl, UI, automation) arrives here first. It authenticates and validates the request, then stores it in etcd | Receptionist at head office |
| Scheduler (`kube-scheduler`) | Decides which worker node a new Pod runs on, based on free CPU, memory and rules | Kitchen manager assigning orders to free chefs |
| Controller Manager (`kube-controller-manager`) | Constantly compares the **desired state** with the **actual state** and acts on any difference | Supervisor: "we need 5 people, only 4 came, call one more" |
| etcd | Distributed key-value database holding the whole cluster state | The company's master register (single source of truth) |

### Desired state vs actual state

This is the most important idea in Kubernetes.

- **Desired state** = what you asked for in YAML ("5 nginx pods").
- **Actual state** = what is really running ("4 pods").

The controller sees the gap and creates one more Pod. This never-ending check-and-fix loop is the **reconciliation loop**.

> **Why etcd matters:** if etcd data is lost, the cluster no longer knows what should be running. Production clusters back up etcd regularly.

## 4. Worker nodes: the hands

A worker node is a VM, EC2 instance or physical server where your application containers run.

| Component | Job | Analogy |
| --- | --- | --- |
| kubelet | Agent on every node. Takes instructions from the API Server, starts Pods, and reports their health | Caretaker of the node |
| kube-proxy | Programs networking rules so Service traffic reaches the right Pods | Traffic police |
| Container runtime | Actually starts and stops containers (containerd, CRI-O) | The engine of the car |

Two more things every cluster needs:

- **CNI plugin** (Calico, Flannel, Cilium): gives every Pod an IP and lets Pods on different nodes talk. Without a CNI, nodes stay `NotReady`.
- **CoreDNS**: the cluster's DNS, so a Pod can reach a Service by name (`notes-svc.notes-ns.svc.cluster.local`).

`kubectl` is a **client tool**. It is not part of the control plane or the workers; it runs on your laptop or admin machine and sends commands to the API Server. The file `~/.kube/config` tells it which cluster to talk to.

## 5. Architecture at a glance

```text
                        +---------------------- Control plane ----------------------+
 kubectl  ---------->   |  API Server  <---->  etcd                                 |
                        |      ^                                                    |
                        |      |  watch                                             |
                        |  Scheduler        Controller Manager                     |
                        +------|----------------------------------------------------+
                               |
            +------------------+------------------+
            v                                     v
   +---- Worker node 1 ----+             +---- Worker node 2 ----+
   | kubelet   kube-proxy  |             | kubelet   kube-proxy  |
   | containerd            |             | containerd            |
   | [Pod] [Pod] [Pod]     |  <-- CNI -->| [Pod] [Pod]           |
   +-----------------------+             +-----------------------+
```

## 6. How a Pod is created, and how self-healing works

### Flow A: from `kubectl apply` to a running Pod

1. **User** runs `kubectl apply -f deployment.yaml`. kubectl sends the request to the API Server.
2. **API Server** authenticates and validates it, then saves it to etcd.
3. **Controller Manager** sees a new Deployment and creates a ReplicaSet and the Pod objects (not yet on any node).
4. **Scheduler** picks the best node for each unassigned Pod and tells the API Server.
5. **kubelet** on that node sees "a new Pod is assigned to me".
6. **containerd** pulls the image and starts the container.
7. **CNI** gives the Pod an IP; **kube-proxy** updates Service rules.

### Flow B: a Pod crashes

1. **Detect:** kubelet reports the failed Pod to the API Server.
2. **Compare:** Controller Manager sees desired = 5, actual = 4.
3. **Act:** it creates a new Pod object.
4. **Schedule:** the Scheduler places it on a node with room.
5. **Run:** that node's kubelet starts the container. The count is 5 again.

No human was involved. That is self-healing. You will see it live in Module 3 with `kubectl delete pod`.

## 7. Tools to run Kubernetes

| Tool | What it is | Used for | Limitation |
| --- | --- | --- | --- |
| Kind (Kubernetes in Docker) | Runs cluster "nodes" as Docker containers; supports multi-node | Learning, CI pipelines, fast testing | Not for production |
| Minikube | Single-node cluster on a laptop, many add-ons | Beginners, local development | Not for production |
| kubeadm | Official installer that builds a real cluster on VMs or servers | Self-managed production, private data centres | You add CNI, load balancer, monitoring yourself |
| AWS EKS / Azure AKS / Google GKE | Cloud provider runs and upgrades the control plane | Most common in industry | Cloud cost, vendor dependency |
| Red Hat OpenShift | Enterprise platform with extra CI/CD, security and developer tools | Large enterprises | License cost |

**In this course:** Kind for Modules 2-12 (fast, free, 3 nodes on one EC2), and kubeadm on three EC2 instances in Module 13.

## 8. Practice questions

| # | Question | Answer |
| --- | --- | --- |
| 1 | Name 3 Docker limitations that Kubernetes solves | Auto-scaling, load balancing, self-healing (also monitoring, multi-host) |
| 2 | Which component receives a `kubectl apply` request first? | API Server |
| 3 | Who decides which node a Pod runs on? | Scheduler |
| 4 | Who notices the gap between desired and actual state? | Controller Manager |
| 5 | Where is the whole cluster state stored? | etcd |
| 6 | Which agent starts Pods on a worker node? | kubelet |
| 7 | Who gives Pods their IPs? | The CNI plugin (Calico, Flannel, Cilium) |
| 8 | Is kubectl part of the master or the worker? | Neither; it is a client tool |
| 9 | Is Docker a CNCF graduated project? | No. containerd (donated by Docker) is |
| 10 | Kind or kubeadm/EKS for production? | kubeadm or a managed service; Kind is for learning and CI |

## Sources

- [Kubernetes Components](https://kubernetes.io/docs/concepts/overview/components/)
- [CNCF announces containerd graduation](https://www.cncf.io/announcements/2019/02/28/cncf-announces-containerd-graduation/)
