#!/usr/bin/env bash
# =====================================================================
# k8s-setup.sh
# Sets up a kubeadm Kubernetes cluster on Ubuntu (AWS EC2).
#
# Modes (always run with sudo):
#   Master : sudo ./k8s-setup.sh master
#   Worker : sudo ./k8s-setup.sh worker <hostname> "<join command>"
#   Reset  : sudo ./k8s-setup.sh reset
#
# Flow:
#   1. Run "master" mode on the master node.
#   2. At the end it prints one ready command for worker-1 and one for worker-2.
#   3. Copy each command to its worker and run it.
# =====================================================================

set -euo pipefail

# ---------------------------------------------------------------------
# Settings (change here if needed)
# ---------------------------------------------------------------------
K8S_VERSION="v1.36"                  # Kubernetes minor version (apt repo)
CALICO_VERSION="v3.33.0"             # Calico CNI manifest version
POD_CIDR="192.168.0.0/16"            # Pod network (Calico default, no clash with AWS 172.31.0.0/16)
MASTER_NAME="master"                 # Hostname for the master node
WORKER_NAMES=("worker-1" "worker-2") # Hostnames for workers (one command is printed per name)
UBUNTU_MIRROR=""                     # Optional: e.g. "http://mirror.kakao.com/ubuntu" if the default mirror is down

CRI_SOCKET="unix:///run/containerd/containerd.sock"
TOTAL_STEPS=11

# ---------------------------------------------------------------------
# Output helpers: colored messages so students can see what is happening
# ---------------------------------------------------------------------
GREEN='\033[0;32m'; RED='\033[0;31m'; YELLOW='\033[1;33m'; BLUE='\033[1;34m'; NC='\033[0m'

step() { echo; echo -e "${BLUE}========== [STEP $1/${TOTAL_STEPS}] $2 ==========${NC}"; }
info() { echo -e "${GREEN}[INFO]${NC} $*"; }
ok()   { echo -e "${GREEN}[OK]${NC}   $*"; }
warn() { echo -e "${YELLOW}[WARN]${NC} $*"; }
die()  { echo -e "${RED}[ERROR]${NC} $*" >&2; exit 1; }

usage() {
  cat <<'EOF'
Usage:
  sudo ./k8s-setup.sh master
  sudo ./k8s-setup.sh worker <hostname> "<join command printed by master>"
  sudo ./k8s-setup.sh reset

Examples:
  sudo ./k8s-setup.sh master
  sudo ./k8s-setup.sh worker worker-1 "kubeadm join 172.31.10.100:6443 --token abc.123 --discovery-token-ca-cert-hash sha256:xyz"
  sudo ./k8s-setup.sh reset
EOF
  exit 1
}

# The script changes system settings, so it must run as root.
[[ $EUID -eq 0 ]] || die "Run with sudo: sudo $0 $*"

MODE="${1:-}"
REAL_USER="${SUDO_USER:-root}"                           # the user who typed sudo (usually ubuntu)
REAL_HOME="$(getent passwd "$REAL_USER" | cut -d: -f6)" # that user's home folder

# ---------------------------------------------------------------------
# apt helpers
# ---------------------------------------------------------------------

# Wait while another apt/dpkg process (e.g. auto-updates) holds the lock.
# Never delete the lock file: that can break dpkg.
wait_for_apt() {
  while fuser /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock >/dev/null 2>&1; do
    warn "apt is busy (another update is running). Waiting 5 seconds..."
    sleep 5
  done
}

apt_update() {
  wait_for_apt
  apt-get update -y || { warn "apt update failed, retrying in 10 sec"; sleep 10; apt-get update -y || warn "apt update still has errors (a mirror may be down), continuing anyway"; }
}

apt_install() {
  wait_for_apt
  DEBIAN_FRONTEND=noninteractive apt-get install -y "$@"
}

# Optional: point Ubuntu repos to another mirror when the default one is down (503 / timeout).
switch_mirror() {
  [[ -z "$UBUNTU_MIRROR" ]] && return 0
  info "Switching Ubuntu mirror to: $UBUNTU_MIRROR"
  if [[ -f /etc/apt/sources.list.d/ubuntu.sources ]]; then
    sed -i -E "s#http://[^ ]*(archive|security)\.ubuntu\.com/ubuntu/?#${UBUNTU_MIRROR}#g" /etc/apt/sources.list.d/ubuntu.sources
  fi
  if [[ -f /etc/apt/sources.list ]]; then
    sed -i -E "s#http://[^ ]*(archive|security)\.ubuntu\.com/ubuntu/?#${UBUNTU_MIRROR}#g" /etc/apt/sources.list
  fi
  ok "Mirror switched"
}

# Set the hostname BEFORE init/join: the node registers with this name and it cannot be renamed later.
set_hostname() {
  local name="$1"
  if [[ "$(hostname)" != "$name" ]]; then
    info "Setting hostname to: $name"
    hostnamectl set-hostname "$name"
    grep -q "127.0.1.1 $name" /etc/hosts || echo "127.0.1.1 $name" >> /etc/hosts
    ok "Hostname is now: $(hostname)"
  else
    ok "Hostname already correct: $name"
  fi
}

# ---------------------------------------------------------------------
# Common setup: runs on master AND workers (steps 1-11)
# ---------------------------------------------------------------------
common_setup() {

  # STEP 1: stop automatic updates so they do not lock apt during the install
  step 1 "Stopping automatic updates"
  systemctl disable --now unattended-upgrades >/dev/null 2>&1 || true
  wait_for_apt
  dpkg --configure -a
  switch_mirror
  ok "Automatic updates stopped, apt is free"

  # STEP 2: kubelet needs swap off (now and after reboot)
  step 2 "Disabling swap"
  swapoff -a
  sed -i '/ swap / s/^/#/' /etc/fstab
  ok "Swap is off"

  # STEP 3: overlay = container file system layers, br_netfilter = pod traffic goes through iptables
  step 3 "Loading kernel modules: overlay, br_netfilter"
  printf 'overlay\nbr_netfilter\n' > /etc/modules-load.d/k8s.conf
  modprobe overlay
  modprobe br_netfilter
  ok "Kernel modules loaded (and saved for reboot)"

  # STEP 4: let bridged traffic hit iptables and allow packet forwarding between pods
  step 4 "Setting sysctl network parameters"
  printf 'net.bridge.bridge-nf-call-iptables = 1\nnet.bridge.bridge-nf-call-ip6tables = 1\nnet.ipv4.ip_forward = 1\n' > /etc/sysctl.d/k8s.conf
  sysctl --system >/dev/null
  ok "ip_forward = $(sysctl -n net.ipv4.ip_forward)"

  # STEP 5: tools needed to add repos (apt-transport-https is not needed on new Ubuntu)
  step 5 "Installing basic tools: ca-certificates, curl, gpg"
  apt_update
  apt_install ca-certificates curl gpg psmisc
  ok "Basic tools installed"

  # STEP 6: containerd comes from Docker's apt repo
  step 6 "Adding containerd (Docker) apt repository"
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  local codename
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  # Very new Ubuntu releases may not be in Docker's repo yet: fall back to 24.04 (noble)
  if ! curl -fsI "https://download.docker.com/linux/ubuntu/dists/${codename}/Release" >/dev/null 2>&1; then
    warn "Docker repo has no '${codename}' yet, using 'noble' (24.04) instead"
    codename="noble"
  fi
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/ubuntu ${codename} stable" > /etc/apt/sources.list.d/docker.list
  ok "Docker repo added (${codename})"

  # STEP 7: install containerd and use the systemd cgroup driver (same as kubelet)
  step 7 "Installing containerd and setting SystemdCgroup = true"
  apt_update
  apt_install containerd.io
  mkdir -p /etc/containerd
  containerd config default > /etc/containerd/config.toml
  sed -i 's/SystemdCgroup = false/SystemdCgroup = true/' /etc/containerd/config.toml
  grep -q 'SystemdCgroup = true' /etc/containerd/config.toml || die "Could not set SystemdCgroup = true"
  ok "containerd installed, SystemdCgroup = true"

  # STEP 8: official Kubernetes apt repo for the chosen minor version
  step 8 "Adding Kubernetes ${K8S_VERSION} apt repository"
  curl -fsSL "https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/Release.key" | gpg --dearmor --yes -o /etc/apt/keyrings/kubernetes-apt-keyring.gpg
  echo "deb [signed-by=/etc/apt/keyrings/kubernetes-apt-keyring.gpg] https://pkgs.k8s.io/core:/stable:/${K8S_VERSION}/deb/ /" > /etc/apt/sources.list.d/kubernetes.list
  ok "Kubernetes repo added"

  # STEP 9: kubeadm builds the cluster, kubelet runs pods, kubectl is the client.
  # "hold" stops apt upgrade from changing their versions by mistake.
  step 9 "Installing kubelet, kubeadm, kubectl"
  apt_update
  apt-mark unhold kubelet kubeadm kubectl >/dev/null 2>&1 || true
  apt_install kubelet kubeadm kubectl
  apt-mark hold kubelet kubeadm kubectl
  systemctl enable --now kubelet
  ok "Installed: $(kubeadm version -o short) (kubelet restarts until init/join, this is normal)"

  # STEP 10: every pod has a small "pause" container; use the version this kubeadm expects
  step 10 "Setting the correct pause image in containerd"
  local pause
  pause="$(kubeadm config images list 2>/dev/null | grep pause || true)"
  if [[ -n "$pause" ]]; then
    sed -i "s#registry.k8s.io/pause:[0-9.]*#${pause}#" /etc/containerd/config.toml
    ok "Pause image: $pause"
  else
    warn "Could not read the pause version from kubeadm, keeping the default"
  fi
  systemctl restart containerd
  systemctl is-active --quiet containerd || die "containerd did not start"
  ok "containerd restarted and active"

  # STEP 11: quick summary before init/join
  step 11 "Pre-check summary"
  ok "Hostname   : $(hostname)"
  ok "kubeadm    : $(kubeadm version -o short)"
  ok "containerd : $(systemctl is-active containerd)"
}

# ---------------------------------------------------------------------
# Master mode
# ---------------------------------------------------------------------
master_setup() {
  # Safety: do not run init twice on the same machine
  [[ -f /etc/kubernetes/admin.conf ]] && die "A cluster already exists on this machine. Run first: sudo $0 reset"

  echo -e "${BLUE}### MASTER SETUP STARTED on $(hostname -I | awk '{print $1}') ###${NC}"
  set_hostname "$MASTER_NAME"
  common_setup

  # Create the control plane: API server, etcd, scheduler, controller-manager
  echo; echo -e "${BLUE}========== [MASTER 1/5] kubeadm init (1-2 minutes) ==========${NC}"
  kubeadm init --pod-network-cidr="$POD_CIDR" --cri-socket "$CRI_SOCKET"
  ok "Control plane initialized"

  # Give the normal user (ubuntu) kubectl access
  echo; echo -e "${BLUE}========== [MASTER 2/5] Setting up kubectl for user '$REAL_USER' ==========${NC}"
  mkdir -p "$REAL_HOME/.kube"
  cp -f /etc/kubernetes/admin.conf "$REAL_HOME/.kube/config"
  chown "$(id -u "$REAL_USER"):$(id -g "$REAL_USER")" "$REAL_HOME/.kube/config"
  export KUBECONFIG=/etc/kubernetes/admin.conf
  kubectl cluster-info | head -1
  ok "kubectl ready (check: the IP above must be this master's private IP)"

  # Install the pod network; until then the node stays NotReady
  echo; echo -e "${BLUE}========== [MASTER 3/5] Installing Calico ${CALICO_VERSION} ==========${NC}"
  kubectl apply -f "https://raw.githubusercontent.com/projectcalico/calico/${CALICO_VERSION}/manifests/calico.yaml"
  ok "Calico applied"

  echo; echo -e "${BLUE}========== [MASTER 4/5] Waiting for master to become Ready (max 5 min) ==========${NC}"
  if kubectl wait --for=condition=Ready "node/$(hostname)" --timeout=300s; then
    ok "Master is Ready"
  else
    warn "Master not Ready yet. Check: kubectl get pods -n kube-system"
  fi
  kubectl get nodes -o wide

  # Create a join token and print one ready command per worker
  echo; echo -e "${BLUE}========== [MASTER 5/5] Creating worker join commands ==========${NC}"
  local join out_file="$REAL_HOME/worker-commands.txt"
  join="$(kubeadm token create --print-join-command)"
  : > "$out_file"
  for w in "${WORKER_NAMES[@]}"; do
    echo "sudo ./k8s-setup.sh worker ${w} \"${join}\"" >> "$out_file"
  done
  chown "$REAL_USER" "$out_file"

  echo
  echo -e "${GREEN}======================================================================${NC}"
  echo -e "${GREEN} MASTER READY. Run these commands on the workers (token valid 24 hours)${NC}"
  echo -e "${GREEN}======================================================================${NC}"
  for w in "${WORKER_NAMES[@]}"; do
    echo
    echo -e "${YELLOW}>>> Run on ${w}:${NC}"
    echo "sudo ./k8s-setup.sh worker ${w} \"${join}\""
  done
  echo
  echo -e "${GREEN}Saved in: ${out_file}${NC}"
  echo -e "${GREEN}After both workers join, run here: kubectl get nodes -o wide${NC}"
}

# ---------------------------------------------------------------------
# Worker mode
# ---------------------------------------------------------------------
worker_setup() {
  local name="${1:-}"
  local join="${2:-}"
  [[ -n "$name" && -n "$join" ]] || usage
  join="$(echo "$join" | xargs)"   # trim extra spaces around the pasted command

  # Safety checks: right input, and this node is not already part of a cluster
  [[ "$join" == kubeadm\ join* ]] || die "Third argument must start with 'kubeadm join ...' (inside quotes)"
  [[ -f /etc/kubernetes/admin.conf ]] && die "kubeadm init was run on this worker by mistake. Run first: sudo $0 reset"
  [[ -f /etc/kubernetes/kubelet.conf ]] && die "This node already joined a cluster. Run first: sudo $0 reset"

  echo -e "${BLUE}### WORKER SETUP STARTED: ${name} ###${NC}"
  set_hostname "$name"
  common_setup

  # Check the master API port is reachable before joining (Security Group problem shows up here)
  local master
  master="$(echo "$join" | awk '{print $3}')"
  echo; echo -e "${BLUE}========== [WORKER 1/2] Checking master API at ${master} ==========${NC}"
  timeout 5 bash -c "</dev/tcp/${master%:*}/${master#*:}" 2>/dev/null \
    || die "Cannot reach ${master}. Check Security Group rule: All traffic, source = same SG"
  ok "Master API reachable"

  # Join the cluster as a worker
  echo; echo -e "${BLUE}========== [WORKER 2/2] kubeadm join ==========${NC}"
  # shellcheck disable=SC2086
  $join --cri-socket "$CRI_SOCKET" --v=5

  echo
  echo -e "${GREEN}======================================================================${NC}"
  echo -e "${GREEN} WORKER ${name} JOINED. On master run: kubectl get nodes -o wide${NC}"
  echo -e "${GREEN} (Type 'exec bash' here to see the new hostname in the prompt)${NC}"
  echo -e "${GREEN}======================================================================${NC}"
}

# ---------------------------------------------------------------------
# Reset mode: remove Kubernetes and containerd completely
# ---------------------------------------------------------------------
reset_node() {
  warn "This removes Kubernetes and containerd from this machine. Starting in 5 seconds (Ctrl+C to stop)..."
  sleep 5
  set +e   # keep going even if some items are already gone

  info "[RESET 1/6] kubeadm reset and remove leftover pods"
  command -v kubeadm >/dev/null && kubeadm reset -f --cri-socket "$CRI_SOCKET"
  command -v crictl  >/dev/null && crictl --runtime-endpoint "$CRI_SOCKET" rmp -fa
  systemctl stop kubelet containerd 2>/dev/null

  info "[RESET 2/6] Removing packages"
  wait_for_apt
  apt-mark unhold kubelet kubeadm kubectl 2>/dev/null
  DEBIAN_FRONTEND=noninteractive apt-get purge -y kubelet kubeadm kubectl kubernetes-cni cri-tools containerd.io 2>/dev/null
  apt-get autoremove -y

  info "[RESET 3/6] Removing config and data folders"
  umount /run/calico/cgroup 2>/dev/null   # Calico mounts a cgroup here; unmount before delete
  rm -rf /etc/kubernetes /var/lib/kubelet /var/lib/etcd /etc/cni /opt/cni /var/lib/cni \
         /run/calico /var/lib/calico /etc/containerd /var/lib/containerd \
         "$REAL_HOME/.kube" /root/.kube "$REAL_HOME/worker-commands.txt"

  info "[RESET 4/6] Removing apt repos and kernel config"
  rm -f /etc/apt/sources.list.d/kubernetes.list /etc/apt/sources.list.d/docker.list \
        /etc/apt/keyrings/kubernetes-apt-keyring.gpg /etc/apt/keyrings/docker.asc \
        /etc/modules-load.d/k8s.conf /etc/sysctl.d/k8s.conf

  info "[RESET 5/6] Flushing iptables rules"
  iptables -F; iptables -t nat -F; iptables -t mangle -F; iptables -X

  info "[RESET 6/6] Removing Calico network interfaces"
  ip link delete vxlan.calico 2>/dev/null
  ip link delete cni0 2>/dev/null

  echo
  echo -e "${GREEN}======================================================================${NC}"
  echo -e "${GREEN} RESET DONE. Now reboot: sudo reboot${NC}"
  echo -e "${GREEN}======================================================================${NC}"
}

# ---------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------
case "$MODE" in
  master) master_setup ;;
  worker) worker_setup "${2:-}" "${3:-}" ;;
  reset)  reset_node ;;
  *)      usage ;;
esac
