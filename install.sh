#!/usr/bin/env bash
# Rubik Pi 3 — RKE2 Kubernetes Cluster Installer
#
# Usage:
#   Init node (first Pi, bootstraps the cluster):
#     sudo [METALLB_RANGE="192.168.1.200-192.168.1.220"] ./install.sh
#
#   Join node (all subsequent Pis — control plane by default):
#     sudo CLUSTER_SERVER="https://<init-node-ip>:9345" \
#          CLUSTER_TOKEN="<token-from-init-output>" \
#          ./install.sh
#
#   Join as pure worker (recommended for 4+ nodes):
#     sudo CLUSTER_SERVER="https://<init-node-ip>:9345" \
#          CLUSTER_TOKEN="<token>" \
#          CLUSTER_ROLE=agent \
#          ./install.sh
#
# Environment variables:
#   CLUSTER_SERVER           — set when joining; absent = init mode
#   CLUSTER_TOKEN            — required when joining
#   CLUSTER_ROLE             — "server" (default) or "agent"
#   METALLB_RANGE            — IP range for MetalLB (init node only)
#   RANCHER_PASSWORD         — Rancher bootstrap password (default: rubikpi-admin)

set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${BLUE}[→]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BOLD}${BLUE}── $* ──${NC}"; }

# ── Configuration ──────────────────────────────────────────────────────────────
CLUSTER_SERVER="${CLUSTER_SERVER:-}"
CLUSTER_TOKEN="${CLUSTER_TOKEN:-}"
CLUSTER_ROLE="${CLUSTER_ROLE:-server}"
METALLB_RANGE="${METALLB_RANGE:-}"
RANCHER_PASSWORD="${RANCHER_PASSWORD:-rubikpi-admin}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RKE2_CONFIG_DIR="/etc/rancher/rke2"
RKE2_DATA_DIR="/var/lib/rancher/rke2"
KUBECONFIG_PATH="${RKE2_CONFIG_DIR}/rke2.yaml"
RKE2_KUBECTL="${RKE2_DATA_DIR}/bin/kubectl"

# ── Helpers ────────────────────────────────────────────────────────────────────
require_root() {
  [[ $EUID -eq 0 ]] || err "Run this script as root: sudo ./install.sh"
}

detect_node_ip() {
  ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1
}

suggest_metallb_range() {
  local ip="$1"
  local prefix
  prefix=$(echo "$ip" | cut -d. -f1-3)
  echo "${prefix}.200-${prefix}.220"
}

generate_token() {
  if command -v openssl &>/dev/null; then
    openssl rand -hex 32
  else
    tr -dc 'a-f0-9' < /dev/urandom | head -c 64
  fi
}

# Read the active cluster token — prefer the server-written token file which is
# what RKE2 actually uses at runtime, fall back to generating a new one.
resolve_token() {
  local server_token_file="${RKE2_DATA_DIR}/server/token"
  if [[ -f "$server_token_file" ]]; then
    cat "$server_token_file"
  else
    generate_token
  fi
}

# ── Qualcomm hardware SDK stack (run on every node) ───────────────────────────
# The Rubik Pi 3 Ubuntu base image ships three pre-configured apt repositories:
#   apt.thundercomm.com/rubik-pi-3/noble   — board-specific / Thundercomm packages
#   tangshan.archive.canonical.com          — Canonical Qualcomm Ubuntu archive
#   ppa:ubuntu-qcom-iot/qcom-ppa            — Qualcomm IoT PPA
# These repos provide the Adreno driver, FastRPC, GStreamer Qualcomm plugins,
# QNN, and SNPE packages.  The install step below just makes sure the relevant
# packages are actually installed on every node (they are not all in the default
# minimal image).
install_qcom_hw_stack() {
  step "Installing Qualcomm hardware SDK stack"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq

  # ── Linux firmware ─────────────────────────────────────────────────────────
  # Required for GPU (Adreno), NPU (Hexagon HTP), and VPU (msm_vidc) firmware
  # blobs to be loaded by the kernel at device initialisation time.
  apt-get install -y -qq linux-firmware || true

  # ── Qualcomm AI inference SDKs ─────────────────────────────────────────────
  # QNN (Qualcomm Neural Network) — provides backends for HTP (NPU Hexagon),
  # GPU, DSP, and CPU inference.  Required by any workload using the NPU.
  # SNPE (Snapdragon Neural Processing Engine) — older SDK, still used by many
  # existing models and by GStreamer's mlsnpe plugin.
  apt-get install -y -qq \
    libqnn1 libqnn-dev qnn-tools \
    libsnpe1 libsnpe-dev snpe-tools

  # ── Adreno GPU OpenCL ICD ──────────────────────────────────────────────────
  # Provides libOpenCL_adreno.so, libadreno_utils.so, and the adreno.icd
  # entry that the OCL ICD loader uses to enumerate the Adreno GPU platform.
  apt-get install -y -qq qcom-adreno1 || true

  # ── FastRPC userspace libraries ────────────────────────────────────────────
  # libcdsprpc.so / libadsprpc.so — needed to open RPC sessions to CDSP
  # (Hexagon NPU/CDSP) and ADSP from userspace.  The kernel-side daemons
  # (cdsprpcd, adsprpcd) are pre-installed; ensure the userspace libs match.
  # qcom-property-vault — provides libpropertyvault.so which the Adreno OCL
  # ICD uses for Android-style system properties on Linux.
  apt-get install -y -qq \
    qcom-fastrpc1 qcom-fastrpc-dev \
    qcom-property-vault || true

  # ── Ensure FastRPC daemons are enabled and running ─────────────────────────
  # cdsprpcd handles CDSP (Hexagon 790 HTP/compute DSP).
  # adsprpcd handles ADSP (audio/sensor DSP).
  # Both must be running before any QNN HTP or FastRPC ioctl calls.
  systemctl enable --now cdsprpcd 2>/dev/null || true
  systemctl enable --now adsprpcd 2>/dev/null || true
  log "FastRPC daemons enabled (cdsprpcd, adsprpcd)"

  # ── CPU OpenCL via POCL ────────────────────────────────────────────────────
  # POCL provides a full OpenCL 3.0 implementation on the ARM CPU, useful for
  # testing OpenCL kernels without a GPU driver.
  # ocl-icd-opencl-dev / opencl-headers — needed to compile OpenCL programs.
  apt-get install -y -qq \
    pocl-opencl-icd \
    ocl-icd-opencl-dev \
    opencl-headers \
    opencl-clhpp-headers \
    clinfo

  # ── V4L2 / GStreamer tools ─────────────────────────────────────────────────
  # v4l-utils — v4l2-ctl, v4l2-compliance: inspect and test video devices
  #              (msm_vidc VPU encoder at /dev/video32-33).
  # gstreamer1.0-tools + plugins-bad — gst-launch-1.0 pipeline tool and the
  #   v4l2h264enc element used to drive the VPU from scripts/containers.
  # The Qualcomm GStreamer plugins (gstreamer1.0-plugins-qcom-*) are already
  # pre-installed by the Thundercomm/Tangshan repos in the base image.
  apt-get install -y -qq \
    v4l-utils \
    gstreamer1.0-tools \
    gstreamer1.0-plugins-bad

  # ── C++ build toolchain ────────────────────────────────────────────────────
  # Required to compile the hw_bench C++ benchmark on the node itself.
  # cmake ≥ 3.16, g++13, libdrm-dev for DRM/KMS device queries.
  apt-get install -y -qq \
    cmake \
    build-essential \
    g++ \
    libdrm-dev

  # ── libOpenCL.so linker symlink ─────────────────────────────────────────────
  # qcom-adreno1 ships libOpenCL.so.1 (the runtime) but NOT the bare linker
  # name libOpenCL.so that the compiler needs for -lOpenCL.
  # ocl-icd-opencl-dev would normally create this symlink, but it conflicts
  # with qcom-adreno1 (it would replace the Adreno ICD with the generic one,
  # losing GPU OpenCL).  Create the symlink explicitly instead.
  local ocl_lib="/usr/lib/aarch64-linux-gnu/libOpenCL.so"
  if [[ ! -e "$ocl_lib" && -e "${ocl_lib}.1" ]]; then
    ln -sf libOpenCL.so.1 "$ocl_lib"
    log "Created linker symlink: ${ocl_lib} → libOpenCL.so.1"
  fi

  log "Qualcomm hardware SDK stack installed"
}

# ── System preparation (run on every node before RKE2) ────────────────────────
prepare_system() {
  step "Preparing system"

  export DEBIAN_FRONTEND=noninteractive
  apt-get update -qq
  # open-iscsi + iscsid: required by Longhorn for block storage
  # nfs-common: required by Longhorn for backup NFS targets
  # util-linux: provides findmnt/blkid used by Longhorn
  apt-get install -y -qq curl openssl open-iscsi nfs-common util-linux

  # Enable iscsid — Longhorn requires it to be running on every node
  systemctl enable iscsid 2>/dev/null || true
  systemctl start  iscsid 2>/dev/null || true
  log "iSCSI daemon enabled and started"

  # ── Swap ──
  # Kubernetes requires swap off for predictable resource management
  if swapon --show 2>/dev/null | grep -q .; then
    info "Disabling swap..."
    swapoff -a
  fi
  sed -i.bak 's|^\([^#].*\s\+swap\s.*\)$|# \1|g' /etc/fstab
  log "Swap disabled"

  # ── Kernel modules ──
  modprobe overlay      2>/dev/null || warn "modprobe overlay failed (may already be built-in)"
  modprobe br_netfilter 2>/dev/null || warn "modprobe br_netfilter failed"
  modprobe iscsi_tcp    2>/dev/null || warn "modprobe iscsi_tcp failed (Longhorn may still work)"

  cat > /etc/modules-load.d/k8s.conf <<'EOF'
overlay
br_netfilter
iscsi_tcp
EOF
  log "Kernel modules configured"

  # ── Sysctl ──
  cat > /etc/sysctl.d/k8s.conf <<'EOF'
net.bridge.bridge-nf-call-iptables  = 1
net.bridge.bridge-nf-call-ip6tables = 1
net.ipv4.ip_forward                 = 1
EOF
  sysctl --system -q
  log "Sysctl networking settings applied"

  # ── NetworkManager ──
  if systemctl is-active --quiet NetworkManager 2>/dev/null; then
    mkdir -p /etc/NetworkManager/conf.d
    cat > /etc/NetworkManager/conf.d/rke2-cni.conf <<'EOF'
[keyfile]
unmanaged-devices=interface-name:cni0;interface-name:flannel.1;interface-name:veth*;interface-name:calico*;interface-name:canal*
EOF
    systemctl reload NetworkManager 2>/dev/null || true
    log "NetworkManager configured to ignore CNI interfaces"
  fi

  # ── UFW firewall ──
  if command -v ufw &>/dev/null && ufw status 2>/dev/null | grep -q "Status: active"; then
    info "Configuring UFW rules for RKE2..."
    ufw allow 6443/tcp  comment 'RKE2 Kubernetes API server'      2>/dev/null
    ufw allow 9345/tcp  comment 'RKE2 supervisor API (node join)' 2>/dev/null
    ufw allow 10250/tcp comment 'Kubelet metrics'                 2>/dev/null
    ufw allow 8472/udp  comment 'RKE2 Canal/Flannel VXLAN'        2>/dev/null
    ufw allow 2379/tcp  comment 'etcd client'                     2>/dev/null
    ufw allow 2380/tcp  comment 'etcd peer'                       2>/dev/null
    ufw allow 7946/tcp  comment 'MetalLB memberlist'              2>/dev/null
    ufw allow 7946/udp  comment 'MetalLB memberlist'              2>/dev/null
    ufw allow 80/tcp    comment 'HTTP ingress (Traefik)'          2>/dev/null
    ufw allow 443/tcp   comment 'HTTPS ingress (Traefik)'         2>/dev/null
    ufw reload 2>/dev/null || true
    log "UFW rules configured"
  else
    info "UFW not active — skipping firewall configuration"
  fi
}

# ── Prerequisites ──────────────────────────────────────────────────────────────
install_prereqs() {
  step "Installing prerequisites"

  if ! command -v helm &>/dev/null; then
    info "Installing Helm..."
    curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash -s -- --no-sudo 2>/dev/null || \
      curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash
  else
    log "Helm $(helm version --short 2>/dev/null | grep -oP 'v[0-9.]+' | head -1) already installed"
  fi
}

# ── kubectl / kubeconfig setup ─────────────────────────────────────────────────
setup_kubectl() {
  step "Setting up kubectl"

  if [[ ! -e /usr/local/bin/kubectl ]]; then
    ln -sf "${RKE2_KUBECTL}" /usr/local/bin/kubectl
  fi

  export KUBECONFIG="$KUBECONFIG_PATH"

  local home_dir
  home_dir=$(getent passwd ubuntu 2>/dev/null | cut -d: -f6 || echo "/home/ubuntu")
  if [[ -d "$home_dir" ]]; then
    mkdir -p "${home_dir}/.kube"
    install -m 600 -o ubuntu -g ubuntu "$KUBECONFIG_PATH" "${home_dir}/.kube/config" 2>/dev/null || true
    local bashrc="${home_dir}/.bashrc"
    if ! grep -q "KUBECONFIG" "$bashrc" 2>/dev/null; then
      {
        echo ""
        echo "# RKE2 Kubernetes"
        echo "export PATH=\$PATH:/var/lib/rancher/rke2/bin"
        echo "export KUBECONFIG=/etc/rancher/rke2/rke2.yaml"
      } >> "$bashrc"
    fi
  fi

  log "kubectl configured (KUBECONFIG=${KUBECONFIG_PATH})"
}

# ── Wait helpers ───────────────────────────────────────────────────────────────
wait_for_node_ready() {
  local node="$1"
  local max="${2:-72}"   # 6 min
  info "Waiting for node '${node}' to become Ready..."
  local i
  for i in $(seq 1 "$max"); do
    if "$RKE2_KUBECTL" get node "$node" --no-headers 2>/dev/null | grep -q " Ready"; then
      log "Node '${node}' is Ready"
      return 0
    fi
    echo -n "."
    sleep 5
  done
  echo
  err "Timed out waiting for node '${node}' — check: journalctl -u rke2-server -f"
}

wait_for_lb_ip() {
  local svc="$1"
  local ns="$2"
  local max="${3:-24}"   # 2 min
  # All diagnostic output goes to stderr so callers can safely capture stdout
  # to get just the IP address without ANSI codes contaminating it.
  info "Waiting for LoadBalancer IP on ${ns}/${svc}..." >&2
  local i ip
  for i in $(seq 1 "$max"); do
    ip=$("$RKE2_KUBECTL" get svc "$svc" -n "$ns" \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [[ -n "$ip" ]]; then
      echo "$ip"
      return 0
    fi
    echo -n "." >&2
    sleep 5
  done
  echo >&2
  return 1
}

wait_for_pods() {
  local ns="$1"
  local selector="$2"
  local max="${3:-60}"
  info "Waiting for pods ready: -n ${ns} -l ${selector}..."
  local i
  for i in $(seq 1 "$max"); do
    local total running
    total=$("$RKE2_KUBECTL" get pods -n "$ns" -l "$selector" --no-headers 2>/dev/null | wc -l || echo 0)
    running=$("$RKE2_KUBECTL" get pods -n "$ns" -l "$selector" --no-headers 2>/dev/null | grep -c "Running" || true)
    if [[ "$total" -gt 0 && "$running" -eq "$total" ]]; then
      log "All pods ready in ${ns}"
      return 0
    fi
    echo -n "."
    sleep 5
  done
  echo
  warn "Pods in ${ns} (${selector}) not all ready after timeout — continuing"
}

# ── RKE2 Installation ──────────────────────────────────────────────────────────
install_rke2() {
  local rke2_type="$1"   # server or agent

  if systemctl is-active --quiet "rke2-${rke2_type}" 2>/dev/null; then
    log "rke2-${rke2_type} is already running — skipping RKE2 install"
    return 0
  fi

  info "Downloading and installing RKE2 (${rke2_type})..."
  curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE="$rke2_type" sh -

  systemctl enable "rke2-${rke2_type}"
  systemctl start  "rke2-${rke2_type}"

  log "rke2-${rke2_type} started"
}

# ── Helm chart installs (init node only) ───────────────────────────────────────
# All installs use `helm upgrade --install` so re-runs are fully idempotent.

install_metallb() {
  local range="$1"
  step "Installing MetalLB"

  helm repo add metallb https://metallb.github.io/metallb --force-update 2>/dev/null
  helm repo update metallb 2>/dev/null
  helm upgrade --install metallb metallb/metallb \
    --namespace metallb-system \
    --create-namespace \
    --wait \
    --timeout 5m

  info "Configuring MetalLB IP pool: ${range}"
  "$RKE2_KUBECTL" apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: rubikpi-pool
  namespace: metallb-system
spec:
  addresses:
    - "${range}"
  autoAssign: true
---
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: rubikpi-l2
  namespace: metallb-system
spec:
  ipAddressPools:
    - rubikpi-pool
EOF
  log "MetalLB pool configured"
}

install_traefik() {
  step "Installing Traefik"

  helm repo add traefik https://traefik.github.io/charts --force-update 2>/dev/null
  helm repo update traefik 2>/dev/null

  helm upgrade --install traefik traefik/traefik \
    --namespace traefik \
    --create-namespace \
    --wait \
    --timeout 5m \
    --set "deployment.replicas=1" \
    --set "service.type=LoadBalancer" \
    --set "ingressClass.enabled=true" \
    --set "ingressClass.isDefaultClass=true" \
    --set "providers.kubernetesIngress.publishedService.enabled=true" \
    --set "logs.general.level=INFO"

  log "Traefik installed"
}

install_cert_manager() {
  step "Installing cert-manager"

  helm repo add jetstack https://charts.jetstack.io --force-update 2>/dev/null
  helm repo update jetstack 2>/dev/null

  helm upgrade --install cert-manager jetstack/cert-manager \
    --namespace cert-manager \
    --create-namespace \
    --set crds.enabled=true \
    --wait \
    --timeout 5m

  log "cert-manager installed"
}

install_rancher() {
  local node_ip="$1"
  step "Installing Rancher"

  # Get Traefik's LoadBalancer IP to construct the nip.io hostname.
  # If already installed, read the persisted hostname instead of waiting again.
  local rancher_hostname=""
  if [[ -f "${RKE2_CONFIG_DIR}/rancher-hostname" ]]; then
    rancher_hostname=$(cat "${RKE2_CONFIG_DIR}/rancher-hostname")
    log "Using existing Rancher hostname: ${rancher_hostname}"
  else
    local traefik_ip
    traefik_ip=$(wait_for_lb_ip traefik traefik) || {
      warn "Could not obtain Traefik LoadBalancer IP — falling back to node IP"
      traefik_ip="$node_ip"
    }
    rancher_hostname="rancher.${traefik_ip}.nip.io"
    echo "$rancher_hostname" > "${RKE2_CONFIG_DIR}/rancher-hostname"
  fi

  log "Rancher hostname: ${rancher_hostname}"

  helm repo add rancher-stable https://releases.rancher.com/server-charts/stable --force-update 2>/dev/null
  helm repo update rancher-stable 2>/dev/null

  helm upgrade --install rancher rancher-stable/rancher \
    --namespace cattle-system \
    --create-namespace \
    --set "hostname=${rancher_hostname}" \
    --set "bootstrapPassword=${RANCHER_PASSWORD}" \
    --set "replicas=1" \
    --set "ingress.tls.source=rancher" \
    --set "ingress.ingressClassName=traefik" \
    --set "global.cattle.psp.enabled=false" \
    --wait \
    --timeout 10m

  log "Rancher installed at https://${rancher_hostname}"
}

install_longhorn() {
  step "Installing Longhorn (distributed block storage)"

  helm repo add longhorn https://charts.longhorn.io --force-update 2>/dev/null
  helm repo update longhorn 2>/dev/null

  # defaultReplicaCount=1: required for single-node — Longhorn won't schedule
  # volumes with replica count > number of nodes.
  helm upgrade --install longhorn longhorn/longhorn \
    --namespace longhorn-system \
    --create-namespace \
    --wait \
    --timeout 10m \
    --set "persistence.defaultClass=true" \
    --set "persistence.defaultClassReplicaCount=1" \
    --set "defaultSettings.defaultReplicaCount=1" \
    --set "defaultSettings.storageMinimalAvailablePercentage=10"

  log "Longhorn installed — default StorageClass: longhorn"
}

remove_control_plane_taints() {
  step "Removing control-plane taints"
  "$RKE2_KUBECTL" taint nodes --all node-role.kubernetes.io/control-plane- 2>/dev/null || true
  "$RKE2_KUBECTL" taint nodes --all node-role.kubernetes.io/master-        2>/dev/null || true
  log "Control-plane taints cleared (nodes are schedulable)"
}

install_device_plugin() {
  step "Installing Qualcomm hardware device plugin"

  local manifest="${SCRIPT_DIR}/manifests/qualcomm-device-plugin.yaml"
  if [[ -f "$manifest" ]]; then
    "$RKE2_KUBECTL" apply -f "$manifest"
    log "Qualcomm device plugin applied (DaemonSet will run on every node)"
  else
    warn "manifests/qualcomm-device-plugin.yaml not found — skipping"
  fi
}

apply_session_rbac() {
  step "Applying session RBAC"

  local manifest="${SCRIPT_DIR}/manifests/session-rbac.yaml"
  if [[ -f "$manifest" ]]; then
    "$RKE2_KUBECTL" apply -f "$manifest"
    log "Session RBAC applied"
  else
    warn "manifests/session-rbac.yaml not found — skipping"
  fi
}

# ── Init mode ──────────────────────────────────────────────────────────────────
install_init() {
  local node_ip
  node_ip=$(detect_node_ip) || err "Cannot detect node IP — is the network configured?"
  log "Node IP: ${node_ip}"

  # Prompt for MetalLB range if not provided
  if [[ -z "$METALLB_RANGE" ]]; then
    local suggested
    suggested=$(suggest_metallb_range "$node_ip")
    echo
    echo "MetalLB needs a range of free IP addresses on your local network."
    echo "These IPs will be assigned to LoadBalancer services (Traefik, etc.)."
    echo "They must NOT overlap with IPs assigned by your router's DHCP."
    echo
    read -rp "Enter MetalLB IP range [${suggested}]: " METALLB_RANGE
    METALLB_RANGE="${METALLB_RANGE:-$suggested}"
  fi
  log "MetalLB IP range: ${METALLB_RANGE}"

  # Resolve token: use the running cluster's token if RKE2 is already up,
  # otherwise generate a fresh one. This ensures re-runs print the correct token.
  local token
  token=$(resolve_token)

  # Only write (or re-write) the RKE2 config when the server is not yet running.
  # Re-writing it while running would replace the token with a newly generated
  # one, which would make the join command printed at the end incorrect.
  if ! systemctl is-active --quiet rke2-server 2>/dev/null; then
    step "Writing RKE2 server config (init node)"
    mkdir -p "$RKE2_CONFIG_DIR"
    cat > "${RKE2_CONFIG_DIR}/config.yaml" <<EOF
# RKE2 init node — generated by rubik-kubernetes installer
cluster-init: true
token: "${token}"
write-kubeconfig-mode: "0640"
disable:
  - rke2-servicelb
  - rke2-traefik
tls-san:
  - "${node_ip}"
  - "$(hostname -f 2>/dev/null || hostname)"
EOF
  else
    log "RKE2 already running — preserving existing config"
  fi

  install_rke2 "server"
  setup_kubectl

  local node_hostname
  node_hostname=$(hostname)
  wait_for_node_ready "$node_hostname"

  remove_control_plane_taints

  # Helm charts (only on init node)
  install_metallb "$METALLB_RANGE"
  install_traefik
  install_cert_manager
  install_longhorn
  install_rancher "$node_ip"
  install_device_plugin
  apply_session_rbac

  print_init_summary "$node_ip" "$token"
}

# ── Join mode ──────────────────────────────────────────────────────────────────
install_join() {
  [[ -n "$CLUSTER_TOKEN" ]] || err "CLUSTER_TOKEN is required when joining. Set it to the token printed by the init node."

  local node_ip
  node_ip=$(detect_node_ip) || err "Cannot detect node IP"
  log "Node IP: ${node_ip}"
  log "Joining: ${CLUSTER_SERVER}  (role: ${CLUSTER_ROLE})"

  if [[ "$CLUSTER_ROLE" == "server" ]]; then
    warn "Joining as server (control plane + etcd member)."
    warn "Keep total server count odd (1, 3, 5) for etcd quorum."
    warn "For pure workers (no etcd), re-run with CLUSTER_ROLE=agent"
  fi

  if ! systemctl is-active --quiet "rke2-${CLUSTER_ROLE}" 2>/dev/null; then
    step "Writing RKE2 ${CLUSTER_ROLE} config"
    mkdir -p "$RKE2_CONFIG_DIR"
    cat > "${RKE2_CONFIG_DIR}/config.yaml" <<EOF
# RKE2 join node — generated by rubik-kubernetes installer
server: "${CLUSTER_SERVER}"
token: "${CLUSTER_TOKEN}"
write-kubeconfig-mode: "0640"
tls-san:
  - "${node_ip}"
  - "$(hostname -f 2>/dev/null || hostname)"
EOF
  else
    log "RKE2 already running — preserving existing config"
  fi

  local rke2_type
  [[ "$CLUSTER_ROLE" == "agent" ]] && rke2_type="agent" || rke2_type="server"

  install_rke2 "$rke2_type"
  setup_kubectl

  step "Verifying node is healthy"
  local i
  for i in $(seq 1 60); do
    if systemctl is-active --quiet "rke2-${rke2_type}" 2>/dev/null; then
      if [[ "$rke2_type" == "server" ]]; then
        if curl -sk "https://localhost:9345/ping" &>/dev/null; then
          log "Server node is joined and healthy"
          break
        fi
      else
        if curl -s "http://localhost:10248/healthz" &>/dev/null; then
          log "Agent node is joined and healthy"
          break
        fi
      fi
    fi
    echo -n "."
    sleep 5
  done
  echo

  print_join_summary
}

# ── Summary output ─────────────────────────────────────────────────────────────
print_init_summary() {
  local node_ip="$1"
  local token="$2"
  local rancher_hostname=""

  [[ -f "${RKE2_CONFIG_DIR}/rancher-hostname" ]] && \
    rancher_hostname=$(cat "${RKE2_CONFIG_DIR}/rancher-hostname")

  echo
  echo -e "${BOLD}${GREEN}"
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║        Rubik Pi 3 — Cluster Bootstrap Complete          ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo -e "${NC}"

  if [[ -n "$rancher_hostname" ]]; then
    echo -e "  ${BOLD}Rancher UI${NC}"
    echo -e "  URL:       ${BLUE}https://${rancher_hostname}${NC}"
    echo -e "  Password:  ${YELLOW}${RANCHER_PASSWORD}${NC}"
    echo -e "  (Accept the self-signed certificate in your browser)"
    echo
  fi

  echo -e "  ${BOLD}Longhorn storage UI${NC}"
  echo -e "  Run: ${BLUE}kubectl port-forward -n longhorn-system svc/longhorn-frontend 8080:80${NC}"
  echo -e "  Then open: ${BLUE}http://localhost:8080${NC}"
  echo

  echo -e "  ${BOLD}Add more nodes — run this command on each Pi:${NC}"
  echo
  echo -e "  ${YELLOW}sudo CLUSTER_SERVER=\"https://${node_ip}:9345\" \\${NC}"
  echo -e "  ${YELLOW}     CLUSTER_TOKEN=\"${token}\" \\${NC}"
  echo -e "  ${YELLOW}     ./install.sh${NC}"
  echo
  echo -e "  ${BOLD}Add pure worker nodes (4+ nodes recommended):${NC}"
  echo
  echo -e "  ${YELLOW}sudo CLUSTER_SERVER=\"https://${node_ip}:9345\" \\${NC}"
  echo -e "  ${YELLOW}     CLUSTER_TOKEN=\"${token}\" \\${NC}"
  echo -e "  ${YELLOW}     CLUSTER_ROLE=agent \\${NC}"
  echo -e "  ${YELLOW}     ./install.sh${NC}"
  echo
  echo -e "  ${BOLD}Start an interactive hardware session:${NC}"
  echo -e "  ${BLUE}./scripts/session.sh start <username>${NC}"
  echo -e "  ${BLUE}./scripts/session.sh connect <username>${NC}"
  echo
  echo -e "  ${BOLD}Token (save this!):${NC}"
  echo -e "  ${token}"
  echo
}

print_join_summary() {
  echo
  echo -e "${BOLD}${GREEN}"
  echo "╔══════════════════════════════════════════════════════════╗"
  echo "║        Rubik Pi 3 — Node Joined Cluster                 ║"
  echo "╚══════════════════════════════════════════════════════════╝"
  echo -e "${NC}"
  echo -e "  Role: ${CLUSTER_ROLE}"
  echo
  echo "  The Qualcomm device plugin DaemonSet will automatically"
  echo "  schedule on this node — no further action needed."
  echo
  echo "  Interactive sessions can be started from any node with"
  echo "  cluster access:"
  echo -e "  ${BLUE}./scripts/session.sh start <username>${NC}"
  echo
}

# ── Firmware check ─────────────────────────────────────────────────────────────
check_firmware() {
  if [[ ! -d /lib/firmware/qcom ]]; then
    warn "Qualcomm firmware (/lib/firmware/qcom) not found."
    warn "GPU, NPU, and VPU may fail to initialise."
    warn "Fix: sudo apt install linux-firmware"
    echo
  fi
}

# ── Entrypoint ─────────────────────────────────────────────────────────────────
main() {
  require_root

  echo
  echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${NC}"
  echo -e "${BOLD}║     Rubik Pi 3 — Kubernetes Cluster Installer           ║${NC}"
  echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${NC}"
  echo

  check_firmware
  install_qcom_hw_stack   # QNN, SNPE, Adreno OCL, FastRPC, POCL, V4L2, build tools
  prepare_system          # swap, kernel modules, sysctl, NetworkManager, UFW
  install_prereqs         # helm

  if [[ -z "$CLUSTER_SERVER" ]]; then
    echo -e "  ${BOLD}Mode: INIT${NC} — bootstrapping a new cluster"
    install_init
  else
    echo -e "  ${BOLD}Mode: JOIN${NC} — joining existing cluster at ${CLUSTER_SERVER}"
    install_join
  fi
}

main "$@"
