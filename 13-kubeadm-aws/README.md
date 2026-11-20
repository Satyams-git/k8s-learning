# Module 13: Production-style Cluster with kubeadm on AWS EC2

**Goal:** build a real 3-node cluster (1 master + 2 workers) on AWS EC2 with kubeadm, containerd and Calico, using one script; then run the Notes app on it and reach it through NodePort on every node.
**Prerequisite:** Modules 1-4, an AWS account. **Time:** 3 hours.

| File | What it is |
| --- | --- |
| `k8s-setup.sh` | One script for everything: `master`, `worker`, `reset` modes |
| `manual-install-guide.txt` | The same setup step by step, command by command (to understand what the script does, or to do it by hand) |
| `01-notes-app-nodeport.yaml` | Notes app (3 replicas) + NodePort Service on port 30081 |

Versions: Kubernetes **v1.36**, Calico **v3.33.0**, containerd, Ubuntu 22.04/24.04.

---

## 1. Kind vs kubeadm

| | Kind (Modules 2-12) | kubeadm (this module) |
| --- | --- | --- |
| Nodes | Docker containers on one machine | Real VMs (EC2 instances) |
| Network plugin | kindnet | Calico (you install it) |
| NodePort access | Needs `extraPortMappings` or port-forward | Directly on every node's public IP |
| Good for | Learning, CI tests | Understanding real clusters, CKA exam, self-managed production |

Managed services (EKS, GKE, AKS) run the control plane for you. kubeadm is how you build it yourself, and how you learn what EKS hides.

```text
                 Security Group: Kubernetes-Cluster-SG (All traffic between members)
   +-----------------------------+   +------------------+   +------------------+
   | master (control-plane)      |   | worker-1         |   | worker-2         |
   | api-server :6443, etcd,     |   | kubelet          |   | kubelet          |
   | scheduler, controller-mgr   |   | containerd       |   | containerd       |
   | kubelet, containerd, calico |   | calico-node      |   | calico-node      |
   +-----------------------------+   +------------------+   +------------------+
        kubeadm init                       kubeadm join            kubeadm join
```

## 2. Golden rules

1. Set the **hostname first**, install later. The node name is written into certificates.
2. `kubeadm init` runs **only on the master, only once**.
3. `kubeadm join` runs **only on the workers**.
4. Before every command, check the prompt: `ubuntu@master`, `ubuntu@worker-1`, `ubuntu@worker-2`. Most broken clusters come from running a command on the wrong machine.

## 3. AWS setup

### Security Group (create it before the instances)

EC2 → Security Groups → Create: name `Kubernetes-Cluster-SG`, your VPC. Inbound rules:

| Type | Port | Source | Why |
| --- | --- | --- | --- |
| All traffic | All | `Kubernetes-Cluster-SG` (the SG itself) | Nodes talk to each other on every port and protocol |
| SSH | 22 | My IP | Your login |
| Custom TCP | 30000-32767 | My IP (or 0.0.0.0/0 for a class demo) | NodePort apps in the browser |

**Why "All traffic from the same SG" and not a list of ports?** Calico carries Pod-to-Pod traffic between nodes as **IP-in-IP (IP protocol 4)**. That is neither TCP nor UDP, so a rule list with only TCP ports (6443, 10250, 179...) lets nodes become `Ready` while Pods on different nodes **cannot talk**. The self-referencing rule allows everything, but only between machines in this SG. The full port list is in `manual-install-guide.txt` if you want individual rules (then add "Custom Protocol 4").

### Instances

| Setting | Value |
| --- | --- |
| AMI | Ubuntu 24.04 (or 22.04) |
| Type | `t2.medium` or larger (control plane needs 2 vCPU, 2 GB RAM) |
| Count | 3 (name them master, worker-1, worker-2 in the console) |
| Network | Same VPC/subnet, Security Group `Kubernetes-Cluster-SG` |
| Storage | 20 GB |

## 4. Install with the script

### What the script does

| Mode | Steps |
| --- | --- |
| Common (all nodes) | Set hostname → stop unattended-upgrades → disable swap → kernel modules (`overlay`, `br_netfilter`) → sysctl (IP forwarding) → install containerd with `SystemdCgroup = true` → Kubernetes apt repo → kubelet/kubeadm/kubectl (held) → pause image |
| `master` | `kubeadm init --pod-network-cidr=192.168.0.0/16` → kubeconfig for the `ubuntu` user → Calico → wait for Ready → print one join command per worker |
| `worker` | Safety checks (not already joined, master reachable on 6443) → common steps → `kubeadm join` |
| `reset` | `kubeadm reset`, remove Kubernetes and containerd packages, configs, CNI and iptables leftovers: the node is clean like a fresh machine |

Every step prints `[STEP x/11] ...`, `[OK]`, `[WARN]` or `[ERROR]` with the fix. Settings (versions, Pod CIDR, worker names, an alternative Ubuntu mirror) are at the top of the script.

### Step 1: copy the script to all 3 machines

From your laptop (or `vim k8s-setup.sh` on each node and paste):

```bash
scp -i key.pem k8s-setup.sh ubuntu@<MASTER-PUBLIC-IP>:~ && scp -i key.pem k8s-setup.sh ubuntu@<WORKER1-PUBLIC-IP>:~ && scp -i key.pem k8s-setup.sh ubuntu@<WORKER2-PUBLIC-IP>:~
```

On each node: `chmod +x k8s-setup.sh`.

> **Pasting into vim adds garbage like `\E[O`?** Your terminal sent escape codes. Before pasting run `:set paste` in vim, or use `scp`. Check with `grep -n $'\e' k8s-setup.sh`: no output means clean.

### Step 2: master

```bash
sudo ./k8s-setup.sh master
```

Takes 5-8 minutes. **Expected end of output:**

```text
======================================================================
 MASTER READY. Run these commands on the workers (token valid 24 hours)
======================================================================

>>> Run on worker-1:
sudo ./k8s-setup.sh worker worker-1 "kubeadm join 172.31.x.x:6443 --token ... --discovery-token-ca-cert-hash sha256:..."

>>> Run on worker-2:
sudo ./k8s-setup.sh worker worker-2 "kubeadm join 172.31.x.x:6443 --token ... --discovery-token-ca-cert-hash sha256:..."
```

The commands are also saved to `~/worker-commands.txt`.

### Step 3: workers

Copy the `worker-1` line to worker-1 and run it; the same for worker-2 (they can run at the same time). **Expected at the end:** `This node has joined the cluster` and `WORKER worker-1 JOINED`. Type `exec bash` to see the new hostname in the prompt.

### Step 4: verify on the master

```bash
kubectl get nodes -o wide
```

**Expected** (Ready may take a minute while calico-node starts on the workers):

```text
NAME       STATUS   ROLES           VERSION   INTERNAL-IP
master     Ready    control-plane   v1.36.x   172.31.x.x
worker-1   Ready    <none>          v1.36.x   172.31.x.x
worker-2   Ready    <none>          v1.36.x   172.31.x.x
```

```bash
kubectl label node worker-1 node-role.kubernetes.io/worker= && kubectl label node worker-2 node-role.kubernetes.io/worker= && kubectl get pods -n kube-system -o wide
```

**Expected:** ROLES shows `worker`; all system Pods `Running`, one `calico-node` per node, `coredns` Running.

**Cross-node network test** (proves Calico and the SG are right):

```bash
kubectl create deployment web --image=nginx --replicas=2 && kubectl rollout status deploy/web && kubectl get pods -o wide -l app=web
```

```bash
kubectl run test --image=busybox:1.36 --rm -it --restart=Never -- wget -qO- $(kubectl get pod -l app=web -o jsonpath='{.items[0].status.podIP}')
```

**Expected:** the nginx welcome HTML. A timeout here (while nodes are Ready) almost always means the SG does not allow all traffic between members. Clean up: `kubectl delete deployment web`.

## 5. Hands-on: Notes app with NodePort

| Part of `01-notes-app-nodeport.yaml` | Meaning |
| --- | --- |
| `replicas: 3` + `topologySpreadConstraints` (hostname, `maxSkew: 1`) | Spread Pods across worker-1 and worker-2 |
| `readinessProbe` | Only Ready Pods receive traffic |
| `type: NodePort`, `nodePort: 30081` | Port 30081 opens on **every** node, master included |

```bash
kubectl apply -f 01-notes-app-nodeport.yaml && kubectl rollout status deploy/notes-app -n notes-ns && kubectl get pods,svc -n notes-ns -o wide
```

**Expected:** 3 Pods `Running` on worker-1 and worker-2; `notes-svc NodePort 82:30081/TCP`.

Open in the browser, **all three** should work:

```text
http://<MASTER-PUBLIC-IP>:30081
http://<WORKER1-PUBLIC-IP>:30081
http://<WORKER2-PUBLIC-IP>:30081
```

The master has no Notes Pod, yet its IP works: kube-proxy on every node forwards NodePort traffic to a Pod anywhere in the cluster (through Calico).

```text
Browser → <any-node-IP>:30081 → kube-proxy (iptables) → notes-svc → a notes-app Pod (any node)
```

> **Works on one node only?** The app works on the node whose Pod answers locally but not on the others = cross-node traffic is blocked. Fix the SG rule ("All traffic, source = the same SG").

### Experiments

Watch load balancing (the Notes app shows the serving Pod's hostname, or check the logs):

```bash
for i in $(seq 1 6); do curl -s -o /dev/null -w "%{http_code}\n" http://localhost:30081; done && kubectl logs -n notes-ns -l app=notes-app --prefix --tail=3
```

Self-healing: delete a Pod and watch it come back:

```bash
kubectl delete pod -n notes-ns $(kubectl get pod -n notes-ns -l app=notes-app -o jsonpath='{.items[0].metadata.name}') && kubectl get pods -n notes-ns -o wide -w
```

Node maintenance (Module 10 on real VMs):

```bash
kubectl drain worker-1 --ignore-daemonsets --delete-emptydir-data && kubectl get pods -n notes-ns -o wide
```

**Expected:** all 3 Pods now on worker-2, and the app still opens on all three IPs (even worker-1's: kube-proxy forwards). Notes saved in `emptyDir` on drained Pods are lost (use a PVC for real data, Module 7). Bring it back:

```bash
kubectl uncordon worker-1 && kubectl rollout restart deploy/notes-app -n notes-ns && kubectl get pods -n notes-ns -o wide
```

**Expected:** after the restart, Pods are spread over both workers again (uncordon alone never moves Pods back).

Scale and observe containers at the runtime level on a worker:

```bash
kubectl scale deploy notes-app -n notes-ns --replicas=6 && kubectl get pods -n notes-ns -o wide
```

On a worker: `sudo crictl --runtime-endpoint unix:///run/containerd/containerd.sock ps | grep notes`.

## 6. Live-session doubts and fixes

| Problem | Cause | Fix |
| --- | --- | --- |
| `Unable to acquire the dpkg frontend lock` | unattended-upgrades runs on a fresh EC2 | The script waits for it. Manually: `sudo systemctl stop unattended-upgrades` and wait; **never delete the lock file** |
| `503` / `520` from `archive.ubuntu.com` or `security.ubuntu.com` | Ubuntu mirror temporarily down | Re-run (the script retries apt). Or set `UBUNTU_MIRROR` at the top of the script to another mirror |
| Master shows as `worker-2` (wrong node names) | Hostname set after install, or `init` run on the wrong machine | `sudo ./k8s-setup.sh reset` on that node, then redo with the right mode |
| Join: `connection refused` / timeout to `:6443` | SG rule missing, or wrong master IP | SG "All traffic, same SG"; the script checks this before joining |
| Join: `kubelet.conf already exists`, `Port 10250 is in use`, `ca.crt already exists` | Node already joined, or `init` was run on it | `sudo ./k8s-setup.sh reset`, then join again |
| `kubeadm token create`: `connection refused` | `~/.kube/config` points to an old cluster | `rm -rf ~/.kube && mkdir ~/.kube && sudo cp /etc/kubernetes/admin.conf ~/.kube/config && sudo chown $(id -u):$(id -g) ~/.kube/config` |
| Token expired (after 24h) | Join tokens expire | On the master: `kubeadm token create --print-join-command` |
| Nodes `Ready`, cross-node Pods cannot talk; NodePort works only on some nodes | IP-in-IP (protocol 4) blocked | SG "All traffic, same SG" |
| `coredns` `Pending` | Calico not running yet | `kubectl get pods -n kube-system`; wait or check calico-node logs |
| kube-system Pods `CrashLoopBackOff` | containerd `SystemdCgroup` is false | `grep SystemdCgroup /etc/containerd/config.toml` must be `true`; `sudo systemctl restart containerd kubelet` |
| `rm: cannot remove '/run/calico/cgroup/...'` | It is a mounted filesystem | `sudo umount /run/calico/cgroup` or reboot |
| Script created on Windows: `$'\r': command not found` | CRLF line endings | `sed -i 's/\r$//' k8s-setup.sh` |
| Different AWS region | | Nothing changes in the script; create the SG in that region and keep all 3 instances in one VPC |

## 7. Reset and cleanup

Reset one node (wrong init/join, want to start again):

```bash
sudo ./k8s-setup.sh reset
```

It removes Kubernetes, containerd and network leftovers (reboot afterwards if it says so). Then master → `master` mode again; worker → a **new** join command from the master. The manual equivalent is section **CLEANUP** in `manual-install-guide.txt`.

App cleanup: `kubectl delete -f 01-notes-app-nodeport.yaml`. **Stop or terminate the EC2 instances** when you finish, to avoid charges.

## 8. Assignment

1. Build the cluster with the script, then repeat it once by hand from `manual-install-guide.txt` on a fresh set of instances. Which step does the script do that you forgot?
2. Run the Module 7 MySQL lab on this cluster using a `hostPath` PV on worker-1. Then install the local-path-provisioner and use a dynamic PVC instead.
3. Install Metrics Server (Module 11; you will need `--kubelet-insecure-tls` here too) and run the HPA lab.
4. Remove the "All traffic" SG rule, add only TCP ports 6443, 10250 and 179, and repeat the cross-node test. Explain the result.
5. Take an etcd snapshot on the master: `sudo ETCDCTL_API=3 etcdctl snapshot save /tmp/etcd.db --endpoints=https://127.0.0.1:2379 --cacert=/etc/kubernetes/pki/etcd/ca.crt --cert=/etc/kubernetes/pki/etcd/server.crt --key=/etc/kubernetes/pki/etcd/server.key` (install `etcd-client` first).

## Sources

- [Creating a cluster with kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/create-cluster-kubeadm/)
- [Installing kubeadm](https://kubernetes.io/docs/setup/production-environment/tools/kubeadm/install-kubeadm/)
- [Ports and protocols](https://kubernetes.io/docs/reference/networking/ports-and-protocols/)
- [Calico: install on on-premises / self-managed clusters](https://docs.tigera.io/calico/latest/getting-started/kubernetes/self-managed-onprem/onpremises)
