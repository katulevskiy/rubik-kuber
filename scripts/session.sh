#!/usr/bin/env bash
# Rubik Pi 3 — Interactive Hardware Session Manager
#
# Provisions privileged Kubernetes pods in the "sessions" namespace.
# Each pod gets full access to all Qualcomm QCS6490 hardware interfaces:
#   GPU  (Adreno 643L)    — /dev/dri
#   NPU  (Hexagon CDSP)   — /dev/fastrpc-cdsp
#   ISP  (Spectra 570L)   — /dev/video* (cameras)
#   VPU  (Adreno VPU633)  — /dev/video10+ (video codec)
#   CPU/Memory/Storage     — via privileged access + cgroup resources
#
# Usage:
#   session.sh start   <username> [--node <nodename>]
#   session.sh connect <username>
#   session.sh list
#   session.sh stop    <username>
#   session.sh logs    <username>

set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
NAMESPACE="sessions"
SESSION_IMAGE="${SESSION_IMAGE:-ubuntu:22.04}"
SESSION_CPU_REQ="${SESSION_CPU_REQ:-1}"
SESSION_CPU_LIM="${SESSION_CPU_LIM:-6}"
SESSION_MEM_REQ="${SESSION_MEM_REQ:-512Mi}"
SESSION_MEM_LIM="${SESSION_MEM_LIM:-8Gi}"

KUBECONFIG="${KUBECONFIG:-/etc/rancher/rke2/rke2.yaml}"
KUBECTL="${KUBECTL:-kubectl}"

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${BLUE}[→]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }

# ── Helpers ────────────────────────────────────────────────────────────────────
pod_name() {
  echo "session-${1}"
}

check_kubectl() {
  if ! command -v "$KUBECTL" &>/dev/null; then
    # Try RKE2 bundled kubectl
    if [[ -x /var/lib/rancher/rke2/bin/kubectl ]]; then
      KUBECTL=/var/lib/rancher/rke2/bin/kubectl
    else
      err "kubectl not found. Install it or set KUBECTL=/path/to/kubectl"
    fi
  fi
  export KUBECONFIG
}

# ── start ──────────────────────────────────────────────────────────────────────
cmd_start() {
  local username="${1:-}"
  local target_node=""

  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --node) target_node="${2:-}"; shift 2 ;;
      *) warn "Unknown argument: $1"; shift ;;
    esac
  done

  [[ -n "$username" ]] || err "Usage: session.sh start <username> [--node <nodename>]"

  local pod
  pod=$(pod_name "$username")

  # Check if session already exists
  if "$KUBECTL" get pod "$pod" -n "$NAMESPACE" &>/dev/null; then
    local phase
    phase=$("$KUBECTL" get pod "$pod" -n "$NAMESPACE" -o jsonpath='{.status.phase}' 2>/dev/null || echo "Unknown")
    warn "Session for '${username}' already exists (${phase})"
    info "Connect with: $0 connect ${username}"
    info "Stop with:    $0 stop ${username}"
    return 0
  fi

  info "Starting session for '${username}'..."
  [[ -n "$target_node" ]] && info "Pinning to node: ${target_node}"

  # Build nodeSelector / nodeName stanza
  local node_selector_yaml=""
  if [[ -n "$target_node" ]]; then
    node_selector_yaml="  nodeName: ${target_node}"
  fi

  # Build device plugin resource requests.
  # These ensure the scheduler places the pod on a node that has the devices.
  # The privileged securityContext + /dev mount then gives full hardware access.
  local device_resources
  device_resources=$(cat <<'EOF'
          rubikpi.ai/gpu: "1"
          rubikpi.ai/npu: "1"
EOF
)

  "$KUBECTL" apply -f - <<EOF
apiVersion: v1
kind: Pod
metadata:
  name: ${pod}
  namespace: ${NAMESPACE}
  labels:
    app: rubikpi-session
    session-user: "${username}"
  annotations:
    rubikpi.ai/started-by: "${USER:-unknown}"
    rubikpi.ai/started-at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
spec:
${node_selector_yaml}
  restartPolicy: Never
  hostname: rubikpi
  # Keep the pod alive until explicitly stopped
  terminationGracePeriodSeconds: 10

  containers:
    - name: session
      image: ${SESSION_IMAGE}
      imagePullPolicy: IfNotPresent
      # sleep infinity keeps the pod alive; users exec into it interactively
      command: ["/bin/bash", "-c"]
      args:
        - |
          # Install a minimal set of tools on first start
          export DEBIAN_FRONTEND=noninteractive
          apt-get update -qq 2>/dev/null && \
          apt-get install -y -qq \
            bash curl wget git vim nano htop procps iproute2 \
            python3 python3-pip \
            v4l-utils mesa-utils \
            2>/dev/null || true
          echo "Session ready for ${username}. Hardware available: GPU /dev/dri, NPU /dev/fastrpc-cdsp, ISP /dev/video*, VPU /dev/video10+"
          exec sleep infinity
      stdin: true
      tty: true

      securityContext:
        privileged: true           # Full hardware access
        allowPrivilegeEscalation: true

      env:
        - name: TERM
          value: xterm-256color
        - name: SESSION_USER
          value: "${username}"
        - name: HOME
          value: /root

      resources:
        requests:
          cpu: "${SESSION_CPU_REQ}"
          memory: "${SESSION_MEM_REQ}"
        limits:
          cpu: "${SESSION_CPU_LIM}"
          memory: "${SESSION_MEM_LIM}"

      volumeMounts:
        # Full /dev from the host — provides all hardware interfaces
        - name: dev
          mountPath: /dev
        # /sys for sysfs hardware introspection
        - name: sys
          mountPath: /sys
        # Persistent home directory per user (hostPath — data survives pod restarts)
        - name: home
          mountPath: /root

  volumes:
    - name: dev
      hostPath:
        path: /dev
    - name: sys
      hostPath:
        path: /sys
    - name: home
      hostPath:
        path: /var/lib/rubikpi-sessions/${username}
        type: DirectoryOrCreate
EOF

  info "Pod created — waiting for it to start..."
  local i
  for i in $(seq 1 30); do
    local phase
    phase=$("$KUBECTL" get pod "$pod" -n "$NAMESPACE" \
      -o jsonpath='{.status.phase}' 2>/dev/null || echo "")
    if [[ "$phase" == "Running" ]]; then
      log "Session '${username}' is running"
      break
    elif [[ "$phase" == "Failed" || "$phase" == "Unknown" ]]; then
      err "Pod failed to start (phase=${phase}). Check: kubectl describe pod ${pod} -n ${NAMESPACE}"
    fi
    echo -n "."
    sleep 3
  done
  echo

  local node
  node=$("$KUBECTL" get pod "$pod" -n "$NAMESPACE" \
    -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo "unknown")

  echo
  echo -e "${BOLD}${GREEN}Session '${username}' is ready${NC}"
  echo -e "  Node:  ${node}"
  echo -e "  Image: ${SESSION_IMAGE}"
  echo
  echo -e "  ${BOLD}Connect:${NC}  $0 connect ${username}"
  echo -e "  ${BOLD}Stop:${NC}     $0 stop ${username}"
  echo
  echo "  Hardware available inside the session:"
  echo "    GPU  — /dev/dri/renderD128  (Adreno 643L)"
  echo "    NPU  — /dev/fastrpc-cdsp   (Hexagon CDSP)"
  echo "    ISP  — /dev/video0 ...     (Spectra 570L cameras)"
  echo "    VPU  — /dev/video10 ...    (Adreno VPU633 codec)"
  echo "    CPU  — $(nproc 2>/dev/null || echo "?") cores (Kryo 670)"
  echo
}

# ── connect ────────────────────────────────────────────────────────────────────
cmd_connect() {
  local username="${1:-}"
  [[ -n "$username" ]] || err "Usage: session.sh connect <username>"

  local pod
  pod=$(pod_name "$username")

  local phase
  phase=$("$KUBECTL" get pod "$pod" -n "$NAMESPACE" \
    -o jsonpath='{.status.phase}' 2>/dev/null || echo "")

  case "$phase" in
    Running)  ;;
    Pending)  err "Session '${username}' is still starting. Try again in a moment." ;;
    "")       err "No session found for '${username}'. Start one with: $0 start ${username}" ;;
    *)        err "Session '${username}' is in phase '${phase}' — cannot connect" ;;
  esac

  info "Connecting to session '${username}'..."
  echo -e "(Type ${BOLD}exit${NC} or press Ctrl-D to disconnect without stopping the session)"
  echo

  exec "$KUBECTL" exec -it "$pod" -n "$NAMESPACE" -- bash
}

# ── list ───────────────────────────────────────────────────────────────────────
cmd_list() {
  echo -e "${BOLD}Active sessions:${NC}"
  echo

  local sessions
  sessions=$("$KUBECTL" get pods -n "$NAMESPACE" \
    -l app=rubikpi-session \
    --no-headers \
    -o custom-columns='USER:.metadata.labels.session-user,POD:.metadata.name,STATUS:.status.phase,NODE:.spec.nodeName,AGE:.metadata.creationTimestamp' \
    2>/dev/null || true)

  if [[ -z "$sessions" ]]; then
    echo "  No active sessions."
    echo
    echo -e "  Start one with: ${BLUE}$0 start <username>${NC}"
    return 0
  fi

  printf "  %-20s %-30s %-10s %-20s %s\n" "USER" "POD" "STATUS" "NODE" "AGE"
  printf "  %-20s %-30s %-10s %-20s %s\n" "────────────────────" "──────────────────────────────" "──────────" "────────────────────" "───"

  while IFS= read -r line; do
    local user pod status node ts
    read -r user pod status node ts <<< "$line"

    # Colourize status
    local status_col
    case "$status" in
      Running) status_col="${GREEN}Running${NC}" ;;
      Pending) status_col="${YELLOW}Pending${NC}" ;;
      *)       status_col="${RED}${status}${NC}" ;;
    esac

    # Calculate human-readable age
    local age="?"
    if [[ -n "$ts" ]] && command -v date &>/dev/null; then
      local now start elapsed
      now=$(date +%s 2>/dev/null || echo 0)
      start=$(date -d "$ts" +%s 2>/dev/null || echo "$now")
      elapsed=$(( now - start ))
      if (( elapsed < 3600 )); then
        age="$((elapsed / 60))m"
      elif (( elapsed < 86400 )); then
        age="$((elapsed / 3600))h"
      else
        age="$((elapsed / 86400))d"
      fi
    fi

    printf "  %-20s %-30s " "$user" "$pod"
    echo -e "${status_col}"
    printf "  %-20s %-30s %-10s %-20s %s\n" "" "" "" "$node" "$age"
  done <<< "$sessions"
  echo
}

# ── stop ───────────────────────────────────────────────────────────────────────
cmd_stop() {
  local username="${1:-}"
  [[ -n "$username" ]] || err "Usage: session.sh stop <username>"

  local pod
  pod=$(pod_name "$username")

  if ! "$KUBECTL" get pod "$pod" -n "$NAMESPACE" &>/dev/null; then
    warn "No session found for '${username}'"
    return 0
  fi

  info "Stopping session '${username}'..."
  "$KUBECTL" delete pod "$pod" -n "$NAMESPACE" --grace-period=5

  log "Session '${username}' stopped"
  echo
  warn "Note: files saved to /root inside the session persist at:"
  echo  "  /var/lib/rubikpi-sessions/${username}/ on the node"
}

# ── logs ───────────────────────────────────────────────────────────────────────
cmd_logs() {
  local username="${1:-}"
  [[ -n "$username" ]] || err "Usage: session.sh logs <username>"

  local pod
  pod=$(pod_name "$username")

  "$KUBECTL" logs "$pod" -n "$NAMESPACE" --follow || \
    "$KUBECTL" logs "$pod" -n "$NAMESPACE"
}

# ── usage ──────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF

${BOLD}Rubik Pi 3 — Interactive Hardware Session Manager${NC}

USAGE
  $0 start   <username> [--node <nodename>]  Create a new session
  $0 connect <username>                       Attach to a running session
  $0 list                                     List all sessions
  $0 stop    <username>                       Delete a session
  $0 logs    <username>                       Stream session logs

ENVIRONMENT
  SESSION_IMAGE   Container image (default: ubuntu:22.04)
  SESSION_CPU_LIM CPU limit per session (default: 6)
  SESSION_MEM_LIM Memory limit per session (default: 8Gi)
  KUBECONFIG      Path to kubeconfig (default: /etc/rancher/rke2/rke2.yaml)

HARDWARE AVAILABLE IN SESSIONS
  GPU   /dev/dri/renderD128      Adreno 643L (Mesa Turnip Vulkan / Freedreno GL)
  NPU   /dev/fastrpc-cdsp        Hexagon CDSP (Qualcomm AI Engine)
  ISP   /dev/video0, video1 ...  Spectra 570L ISP / MIPI cameras
  VPU   /dev/video10, video11 .. Adreno VPU633 (H.265/H.264/VP9/AV1)

EXAMPLES
  # Start a session for alice, let scheduler pick the node
  $0 start alice

  # Start a session pinned to a specific Pi
  $0 start bob --node rubikpi-3

  # Connect (drops you into a bash shell with full hardware access)
  $0 connect alice

  # List all running sessions
  $0 list

  # Stop a session (data in /root is kept on the node)
  $0 stop alice

EOF
}

# ── Entrypoint ─────────────────────────────────────────────────────────────────
main() {
  check_kubectl

  local cmd="${1:-}"
  shift || true

  case "$cmd" in
    start)   cmd_start   "$@" ;;
    connect) cmd_connect "$@" ;;
    list)    cmd_list       ;;
    stop)    cmd_stop    "$@" ;;
    logs)    cmd_logs    "$@" ;;
    help|--help|-h|"") usage ;;
    *) err "Unknown command: ${cmd}. Run '$0 help' for usage." ;;
  esac
}

main "$@"
