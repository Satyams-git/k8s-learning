# Setup Kind and kubectl on Ubuntu Linux

This guide installs Docker, Kind and kubectl on an Ubuntu machine (EC2, Linode or a local VM) and creates a 3-node Kubernetes cluster: 1 control-plane node and 2 worker nodes.

**Tested versions:** Kind v0.33.0, kubectl latest stable release.

**Minimum machine size:** 2 vCPU, 4 GB RAM, 20 GB disk (for example t2.medium or t3.medium). Use a bigger machine (t3.large, 8 GB RAM) if you plan to run autoscaling, Helm or Argo CD labs on the same cluster.

---

## Step 0: Update the system and install required tools

```bash
sudo apt-get update
sudo apt-get upgrade -y
sudo apt-get install -y ca-certificates curl gnupg lsb-release conntrack net-tools git wget jq bash-completion
```

---

## Step 1: Install Docker (required by Kind)

Kind runs every Kubernetes node as a Docker container, so Docker Engine must be installed first.

```bash
# Remove old or conflicting packages ("not installed" messages are fine)
for pkg in docker.io docker-doc docker-compose podman-docker containerd runc; do
  sudo apt-get remove -y $pkg
done

# Add Docker's official GPG key
sudo install -m 0755 -d /etc/apt/keyrings
sudo curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
sudo chmod a+r /etc/apt/keyrings/docker.asc

# Add the Docker repository
echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu $(lsb_release -cs) stable" | \
  sudo tee /etc/apt/sources.list.d/docker.list > /dev/null

# Install Docker
sudo apt-get update
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
sudo systemctl enable --now docker

# Verify the installation (with sudo for now)
docker --version
sudo docker run --rm hello-world
```

**Expected output:** the `Hello from Docker!` message.

### Allow Docker without sudo

```bash
sudo usermod -aG docker $USER
exit
```

> **Note:** `exit` closes your SSH session. This is expected. The new group membership only applies after you log in again. (`newgrp docker` works only for the current shell, so logging out is more reliable.)

SSH into the machine again and verify that Docker works **without** sudo:

```bash
docker ps
docker run --rm hello-world
```

**Expected output:** an empty container list and the `Hello from Docker!` message, with no "permission denied" error.

---

## Step 2: Configure Docker log rotation (optional for Kind)

This stops container logs from filling up the disk.

```bash
cat <<EOF | sudo tee /etc/docker/daemon.json
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "100m",
    "max-file": "3"
  }
}
EOF

sudo systemctl restart docker
```

> **Note:** If `/etc/docker/daemon.json` already exists, this command overwrites it. Check its contents first if you have customised Docker before.

---

## Step 3: Networking modules and sysctl settings

```bash
echo 'br_netfilter' | sudo tee /etc/modules-load.d/br_netfilter.conf
sudo modprobe br_netfilter

cat <<EOF | sudo tee /etc/sysctl.d/kubernetes.conf
net.bridge.bridge-nf-call-ip6tables = 1
net.bridge.bridge-nf-call-iptables  = 1
net.ipv4.ip_forward                 = 1
# Required for multi-node Kind clusters: prevents "too many open files" errors
fs.inotify.max_user_watches         = 524288
fs.inotify.max_user_instances       = 512
EOF

sudo sysctl --system
```

Verify the settings:

```bash
sysctl net.ipv4.ip_forward
sysctl net.bridge.bridge-nf-call-iptables
sysctl fs.inotify.max_user_watches fs.inotify.max_user_instances
```

**Expected output:**

```text
net.ipv4.ip_forward = 1
net.bridge.bridge-nf-call-iptables = 1
fs.inotify.max_user_watches = 524288
fs.inotify.max_user_instances = 512
```

---

## Step 4: Disable swap (optional for Kind)

Kind does not require swap to be disabled. A real kubeadm cluster does, so this step is good practice.

```bash
sudo swapoff -a
sudo sed -i '/\sswap\s/s/^/#/' /etc/fstab
free -h | grep Swap
```

**Expected output:** `Swap:  0B  0B  0B`

---

## Step 5: Install Kind v0.33.0

The command works on both amd64 (Intel/AMD) and arm64 (AWS Graviton) machines.

```bash
KIND_VERSION=v0.33.0
ARCH=$(dpkg --print-architecture)

curl -Lo ./kind https://kind.sigs.k8s.io/dl/${KIND_VERSION}/kind-linux-${ARCH}
chmod +x ./kind
sudo mv ./kind /usr/local/bin/kind

# Verify the installation
kind version
```

**Expected output:** `kind v0.33.0 go1.x.x linux/amd64`

---

## Step 6: Install kubectl (latest stable release)

```bash
ARCH=$(dpkg --print-architecture)
LATEST=$(curl -L -s https://dl.k8s.io/release/stable.txt)
echo "Installing kubectl $LATEST"

# Download the kubectl binary and its checksum
curl -LO "https://dl.k8s.io/release/${LATEST}/bin/linux/${ARCH}/kubectl"
curl -LO "https://dl.k8s.io/release/${LATEST}/bin/linux/${ARCH}/kubectl.sha256"

# Verify the checksum (do not skip this step)
echo "$(cat kubectl.sha256)  kubectl" | sha256sum --check
```

**Expected output:** `kubectl: OK`. If you see `FAILED`, stop and download the files again.

```bash
sudo install -o root -g root -m 0755 kubectl /usr/local/bin/kubectl
rm kubectl kubectl.sha256

# Verify the installation
kubectl version --client
kubectl version --client --output=json
```

---

## Step 7: Set up kubectl autocompletion (optional but recommended)

```bash
cat <<'EOF' >> ~/.bashrc
source <(kubectl completion bash)
alias k=kubectl
complete -o default -F __start_kubectl k
EOF

source ~/.bashrc
```

Now `k` works as a short form of `kubectl`, and pressing `Tab` completes commands and resource names (for example `k get po<Tab>`).

---

## Step 8: Verify all installations

```bash
# Docker
docker --version
docker run --rm hello-world

# Kind
kind version

# kubectl
kubectl version --client

# System checks
echo "CPU cores: $(nproc)"
echo "Memory: $(free -h | grep Mem)"
echo "Disk: $(df -h / | tail -1)"
echo "Swap status: $(free -h | grep Swap)"
sysctl fs.inotify.max_user_watches

# Network checks (curl instead of ping, because EC2 blocks ICMP by default)
curl -s -I https://google.com | head -1
curl -s -I https://kind.sigs.k8s.io/ | head -1
```

**Expected output:** a version for each tool, at least 2 CPU cores and 4 GB memory, swap `0B`, and an `HTTP/2 200` (or `301`) line for each network check.

---

## Step 9: Write the cluster configuration file (cluster.yml)

Kind is now installed, but no cluster exists yet. To create a multi-node cluster (1 control-plane + 2 workers), we describe it in a configuration file, usually named `cluster.yml`.

```bash
mkdir -p ~/k8s-course && cd ~/k8s-course
vim cluster.yml
```

```yaml
kind: Cluster
apiVersion: kind.x-k8s.io/v1alpha4
nodes:
- role: control-plane
  extraPortMappings:
  - containerPort: 30080
    hostPort: 30080
    protocol: TCP
  - containerPort: 30081
    hostPort: 30081
    protocol: TCP
- role: worker
- role: worker
```

### Line-by-line explanation

| Line | Meaning |
| --- | --- |
| `kind: Cluster` | This is a Kind configuration that defines a cluster. It is a Kind file, not a Kubernetes resource. |
| `apiVersion: kind.x-k8s.io/v1alpha4` | The version of the Kind configuration format. `v1alpha4` is the current format. |
| `nodes:` | The list of nodes in the cluster. |
| `- role: control-plane` | The first node is the control-plane (master) node. |
| `extraPortMappings:` | Connects a port on the host machine (EC2) to a port on this node container. |
| `containerPort: 30080` / `hostPort: 30080` | Traffic on the host's port 30080 goes to NodePort 30080 inside the cluster. Without this, NodePort services cannot be opened from a browser, because Kind nodes are Docker containers. |
| `containerPort: 30081` / `hostPort: 30081` | A second port for another NodePort application. |
| `- role: worker` (twice) | Two worker nodes, where application pods will run. |

> **Security group note (EC2):** open inbound ports 30080-30081 (and 22 for SSH), preferably only from your own IP, to reach NodePort apps from a browser.

---

## Step 10: Create the cluster

```bash
kind create cluster --config cluster.yml --name demo-cluster
```

| Flag | Meaning |
| --- | --- |
| `--config cluster.yml` | Use this file to build the cluster. |
| `--name demo-cluster` | The cluster name. Node names and the kubectl context are built from it. If you omit it, the name is `kind`. |

**Expected output (at the end):**

```text
 ✓ Ensuring node image (kindest/node:...)
 ✓ Preparing nodes
 ✓ Writing configuration
 ✓ Starting control-plane
 ✓ Installing CNI
 ✓ Installing StorageClass
 ✓ Joining worker nodes
Set kubectl context to "kind-demo-cluster"
```

The first run takes 2-4 minutes because the node image is downloaded.

---

## Step 11: Verify the cluster

```bash
kubectl cluster-info
kubectl get nodes
```

**Expected output:**

```text
NAME                         STATUS   ROLES           AGE   VERSION
demo-cluster-control-plane   Ready    control-plane   1m    v1.XX.X
demo-cluster-worker          Ready    <none>          1m    v1.XX.X
demo-cluster-worker2         Ready    <none>          1m    v1.XX.X
```

All three nodes must show `Ready`.

See that the nodes are really Docker containers, and that the control-plane components run as pods:

```bash
docker ps --format 'table {{.Names}}\t{{.Image}}\t{{.Ports}}'
kubectl get pods -n kube-system -o wide
```

---

## Useful Kind commands

| Command | What it does |
| --- | --- |
| `kind get clusters` | List all Kind clusters |
| `kind get nodes --name demo-cluster` | List the nodes (containers) of a cluster |
| `kubectl config use-context kind-demo-cluster` | Point kubectl at this cluster |
| `kind load docker-image my-app:v1 --name demo-cluster` | Load a locally built image into the cluster nodes without a registry |
| `kind delete cluster --name demo-cluster` | Delete the cluster (all data is lost) |

---

## Troubleshooting

| Problem | Cause | Fix |
| --- | --- | --- |
| `permission denied ... docker.sock` | User is not in the docker group, or you did not log in again | `sudo usermod -aG docker $USER`, then log out and SSH again |
| `kind create cluster` hangs or fails | Not enough CPU/RAM (for example t2.micro) | Use at least 2 vCPU / 4 GB RAM |
| Pods restart with "too many open files" | inotify limits too low | Apply the Step 3 sysctl settings and recreate the cluster |
| `The connection to the server localhost:8080 was refused` | kubectl has no cluster context | `kubectl config use-context kind-demo-cluster` |
| `node(s) already exist for a cluster with the name "demo-cluster"` | A cluster with that name already exists | `kind delete cluster --name demo-cluster` |
| NodePort app does not open in the browser | Port not open in the security group, or no `extraPortMappings` | Open ports 30080-30081; check `cluster.yml` and recreate the cluster |
