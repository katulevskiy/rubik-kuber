#!/usr/bin/env bash
# Rubik Pi 3 — Interactive Hardware Session Manager
#
# Provisions privileged Kubernetes pods in the "sessions" namespace.
# Each pod gets EXCLUSIVE access to all Qualcomm QCS6490 hardware on the
# scheduled Pi node:
#   GPU  (Adreno 643L)    — /dev/dri, OpenCL via libOpenCL_adreno.so
#   NPU  (Hexagon CDSP)   — /dev/fastrpc-cdsp, QNN HTP backend
#   VPU  (Adreno VPU633)  — /dev/video32-33, V4L2 M2M codec
#   DSP  (Hexagon ADSP)   — /dev/fastrpc-adsp-secure
#   CPU/Memory/Storage     — privileged access + cgroup resources
#
# EXCLUSIVE ACCESS: when a session starts, the Pi node is tainted with
#   rubikpi.ai/exclusive-session=<username>:NoSchedule
# This blocks all new workloads from landing on that node until the session
# is stopped (which removes the taint).  Existing DaemonSet pods are unaffected.
#
# Usage:
#   session.sh start   <username> [--node <nodename>]
#   session.sh connect <username>
#   session.sh list
#   session.sh stop    <username>
#   session.sh logs    <username>
#   session.sh untaint [--all]   # remove orphaned session taints

set -euo pipefail

# ── Config ─────────────────────────────────────────────────────────────────────
NAMESPACE="sessions"
# ubuntu:24.04 matches the host OS version so host /usr/lib overlay is ABI-safe
SESSION_IMAGE="${SESSION_IMAGE:-ubuntu:24.04}"
SESSION_CPU_REQ="${SESSION_CPU_REQ:-1}"
SESSION_CPU_LIM="${SESSION_CPU_LIM:-6}"
SESSION_MEM_REQ="${SESSION_MEM_REQ:-512Mi}"
SESSION_MEM_LIM="${SESSION_MEM_LIM:-8Gi}"

KUBECONFIG="${KUBECONFIG:-/etc/rancher/rke2/rke2.yaml}"
KUBECTL="${KUBECTL:-kubectl}"

# ── CPU core type map (QCS6490 / Kryo 670) ─────────────────────────────────────
# The QCS6490 has three physical CPU clusters:
#
#   silver    Cortex-A55  CPUs 0-3  capacity=382/1024  max=1.96 GHz  efficiency
#   gold      Cortex-A78  CPUs 4-6  capacity=889/1024  max=2.40 GHz  performance
#   gold-plus Cortex-A78  CPU  7    capacity=1024/1024  max=2.71 GHz  prime (boost)
#   gold-all              CPUs 4-7  gold + gold-plus combined
#   all                   CPUs 0-7  no affinity (default)
#
# Used by --cpu-type to set taskset affinity in 'connect'.
cpu_type_to_cores() {
  case "${1:-all}" in
    silver)               echo "0-3" ;;
    gold)                 echo "4-6" ;;
    gold-plus|gold+)      echo "7"   ;;
    gold-all|gold+all)    echo "4-7" ;;
    all|"")               echo "0-7" ;;
    *)                    echo ""    ;;
  esac
}

# Number of physical cores in each CPU type — used to cap POCL worker threads.
# POCL enumerates compute units from total system CPUs (sysconf _SC_NPROCESSORS_ONLN),
# not from the process cpuset.  Without this cap, POCL spawns 8 workers for an
# 8-core system even when taskset restricts execution to e.g. 4 Silver cores,
# causing thread over-subscription and a large performance drop on compute-heavy
# OpenCL kernels.
cpu_type_to_core_count() {
  case "${1:-all}" in
    silver)               echo "4" ;;   # CPUs 0-3
    gold)                 echo "3" ;;   # CPUs 4-6
    gold-plus|gold+)      echo "1" ;;   # CPU 7
    gold-all|gold+all)    echo "4" ;;   # CPUs 4-7
    all|"")               echo ""  ;;   # no cap — let POCL use all CUs
    *)                    echo ""  ;;
  esac
}

cpu_type_description() {
  case "${1:-all}" in
    silver)            echo "Cortex-A55  CPUs 0-3  (efficiency, 1.96 GHz)" ;;
    gold)              echo "Cortex-A78  CPUs 4-6  (performance, 2.40 GHz)" ;;
    gold-plus|gold+)   echo "Cortex-A78  CPU  7    (prime, 2.71 GHz)" ;;
    gold-all|gold+all) echo "Cortex-A78  CPUs 4-7  (performance + prime)" ;;
    all|"")            echo "all 8 cores (no affinity)" ;;
    *)                 echo "unknown" ;;
  esac
}

# Benchmark directory — used for the read-only /benchmark mount inside the pod
# so users can run hw_bench directly without copying files first.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BENCHMARK_DIR="${BENCHMARK_DIR:-${SCRIPT_DIR}/../benchmarks}"
BENCHMARK_DIR="$(cd "${BENCHMARK_DIR}" 2>/dev/null && pwd || echo "")"

# Taint applied to the Pi node while a session is active
SESSION_TAINT_KEY="rubikpi.ai/exclusive-session"

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
    if [[ -x /var/lib/rancher/rke2/bin/kubectl ]]; then
      KUBECTL=/var/lib/rancher/rke2/bin/kubectl
    else
      err "kubectl not found. Install it or set KUBECTL=/path/to/kubectl"
    fi
  fi
  export KUBECONFIG
}

# Apply or remove the exclusive-session taint on a node.
# Usage: taint_node <nodename> <username>   — apply
#        untaint_node <nodename>            — remove
taint_node() {
  local node="$1" username="$2"
  "$KUBECTL" taint node "$node" \
    "${SESSION_TAINT_KEY}=${username}:NoSchedule" --overwrite 2>/dev/null || true
}

untaint_node() {
  local node="$1"
  "$KUBECTL" taint node "$node" "${SESSION_TAINT_KEY}-" 2>/dev/null || true
}

# Return the node a pod is running on, or empty string.
pod_node() {
  local pod="$1"
  "$KUBECTL" get pod "$pod" -n "$NAMESPACE" \
    -o jsonpath='{.spec.nodeName}' 2>/dev/null || echo ""
}

# ── start ──────────────────────────────────────────────────────────────────────
cmd_start() {
  local username="${1:-}"
  local target_node=""
  local cpu_type="all"

  shift || true
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --node)     target_node="${2:-}"; shift 2 ;;
      --cpu-type) cpu_type="${2:-all}"; shift 2 ;;
      *) warn "Unknown argument: $1"; shift ;;
    esac
  done

  [[ -n "$username" ]] || err "Usage: session.sh start <username> [--node <nodename>] [--cpu-type <type>]"

  local cpu_cores
  cpu_cores=$(cpu_type_to_cores "$cpu_type")
  if [[ -z "$cpu_cores" ]]; then
    err "Unknown --cpu-type '${cpu_type}'. Valid: silver, gold, gold-plus, gold-all, all"
  fi

  local pocl_cu_count
  pocl_cu_count=$(cpu_type_to_core_count "$cpu_type")

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
  [[ "$cpu_type" != "all" ]] && info "CPU affinity: ${cpu_type} ($(cpu_type_description "$cpu_type"))"

  # Build nodeName stanza if a specific node was requested
  local node_selector_yaml=""
  if [[ -n "$target_node" ]]; then
    node_selector_yaml="  nodeName: ${target_node}"
  fi

  # Build benchmark mount stanza — only if the benchmark directory exists
  local bench_mount_yaml="" bench_vol_yaml=""
  if [[ -n "$BENCHMARK_DIR" && -d "$BENCHMARK_DIR" ]]; then
    bench_mount_yaml='        - name: benchmark
          mountPath: /benchmark
          readOnly: true'
    bench_vol_yaml="    - name: benchmark
      hostPath:
        path: ${BENCHMARK_DIR}"
  fi

  # ── Create the session pod ─────────────────────────────────────────────────
  # Key design decisions:
  #
  # 1. ALL three device resources are requested (gpu + npu + video).
  #    The device plugin tracks these as finite (capacity=1 each).  Consuming
  #    all three prevents any other pod that needs hardware from scheduling on
  #    the same node via the normal resource-request path.
  #
  # 2. The pod spec does NOT carry a toleration for SESSION_TAINT_KEY.
  #    We apply the taint AFTER the pod is already Running.  This means:
  #      - The pod itself is unaffected (taints only block NEW scheduling).
  #      - Any subsequent pod that lacks the toleration (i.e. every other pod)
  #        is blocked from scheduling on this node for the session's lifetime.
  #
  # 3. /usr/lib and /lib/aarch64-linux-gnu from the HOST are overlaid into the
  #    container.  This gives the container access to all Qualcomm SDKs (QNN,
  #    Adreno OpenCL, FastRPC) without building a custom image.  ubuntu:24.04
  #    (default) matches the host OS so the glibc ABI is identical.
  #
  # 4. /etc/OpenCL from the HOST is overlaid so the OpenCL ICD loader finds
  #    both the Adreno GPU ICD and the POCL CPU ICD.
  #
  # 5. /benchmark is a read-only bind-mount of the hw_bench binary directory,
  #    so users can run /benchmark/build/hw_bench immediately after connecting.

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
    rubikpi.ai/cpu-type: "${cpu_type}"
    rubikpi.ai/cpu-cores: "${cpu_cores}"
spec:
${node_selector_yaml}
  restartPolicy: Never
  hostname: rubikpi
  terminationGracePeriodSeconds: 10

  containers:
    - name: session
      image: ${SESSION_IMAGE}
      imagePullPolicy: IfNotPresent
      command: ["/bin/bash", "-c"]
      args:
        - |
          echo "=== Rubik Pi 3 Hardware Session ==="
          echo "User: ${username}  Node: \$(hostname)"
          echo ""
          echo "Hardware:"
          echo "  GPU  /dev/dri/renderD128   — Adreno 643L  (OpenCL, Vulkan)"
          echo "  NPU  /dev/fastrpc-cdsp     — Hexagon HTP  (QNN)"
          echo "  VPU  /dev/video32          — msm_vidc     (V4L2 M2M H.264)"
          echo "  DSP  /dev/fastrpc-adsp-secure"
          echo ""
          echo "SDKs (from host /usr/lib):"
          echo "  OpenCL  : /usr/lib/aarch64-linux-gnu/libOpenCL.so.1"
          echo "  QNN     : /usr/lib/libQnnHtp.so  /usr/lib/libQnnCpu.so"
          echo "  FastRPC : /usr/lib/aarch64-linux-gnu/libcdsprpc.so"
          echo ""
          if [[ -f /benchmark/build/hw_bench ]]; then
            echo "Benchmark : /benchmark/build/hw_bench  (run as: /benchmark/build/hw_bench)"
          fi
          echo ""
          exec sleep infinity
      stdin: true
      tty: true

      securityContext:
        privileged: true
        allowPrivilegeEscalation: true

      env:
        - name: TERM
          value: xterm-256color
        - name: SESSION_USER
          value: "${username}"
        - name: HOME
          value: /root
        # Make linker find Qualcomm libs that live under /usr/lib/<multiarch>/
        - name: LD_LIBRARY_PATH
          value: "/usr/lib/aarch64-linux-gnu:/usr/lib:/lib/aarch64-linux-gnu"
        # Cap POCL worker threads to match the actual number of available cores.
        # POCL reads total system CPUs (not the process cpuset), so without this
        # it spawns 8 threads even when only e.g. 4 Silver cores are accessible
        # via taskset — causing thread over-subscription and poor OpenCL perf.
        # Empty string when cpu-type=all (POCL uses all CUs, no cap needed).
        - name: POCL_CPU_MAX_CU_COUNT
          value: "${pocl_cu_count}"

      resources:
        requests:
          cpu: "${SESSION_CPU_REQ}"
          memory: "${SESSION_MEM_REQ}"
          rubikpi.ai/gpu: "1"
          rubikpi.ai/npu: "1"
          rubikpi.ai/video: "1"
        limits:
          cpu: "${SESSION_CPU_LIM}"
          memory: "${SESSION_MEM_LIM}"
          rubikpi.ai/gpu: "1"
          rubikpi.ai/npu: "1"
          rubikpi.ai/video: "1"

      volumeMounts:
        # Full /dev and /sys from the host
        - name: dev
          mountPath: /dev
        - name: sys
          mountPath: /sys
        # Host userspace libraries and binaries — gives the container all
        # Qualcomm SDKs (Adreno OpenCL, QNN, FastRPC) and build tools (ld,
        # gcc, cmake) without building a custom image.
        # ABI-safe because SESSION_IMAGE defaults to ubuntu:24.04 = host OS.
        - name: host-usr-bin
          mountPath: /usr/bin
        - name: host-usr-lib
          mountPath: /usr/lib
        - name: host-lib-multiarch
          mountPath: /lib/aarch64-linux-gnu
        # OpenCL ICD configuration — makes clinfo and OpenCL programs find
        # both the Adreno GPU ICD and the POCL CPU ICD.
        - name: host-opencl-icd
          mountPath: /etc/OpenCL
        # POCL runtime headers — required for POCL to JIT-compile OpenCL kernels.
        # POCL resolves its include path relative to libpocl.so as
        # ../../share/pocl/include, which ends up at /usr/share/pocl/include.
        - name: host-pocl-share
          mountPath: /usr/share/pocl
        # Persistent home per user (survives pod restarts on same node)
        - name: home
          mountPath: /root
        # hw_bench binary — users can run it directly without copying files
${bench_mount_yaml}

  volumes:
    - name: dev
      hostPath:
        path: /dev
    - name: sys
      hostPath:
        path: /sys
    - name: host-usr-bin
      hostPath:
        path: /usr/bin
    - name: host-usr-lib
      hostPath:
        path: /usr/lib
    - name: host-lib-multiarch
      hostPath:
        path: /lib/aarch64-linux-gnu
    - name: host-opencl-icd
      hostPath:
        path: /etc/OpenCL
    - name: host-pocl-share
      hostPath:
        path: /usr/share/pocl
    - name: home
      hostPath:
        path: /var/lib/rubikpi-sessions/${username}
        type: DirectoryOrCreate
${bench_vol_yaml}
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
  node=$(pod_node "$pod")

  if [[ -z "$node" ]]; then
    warn "Could not determine node — exclusive taint not applied"
  else
    info "Applying exclusive-session taint to node '${node}'..."
    taint_node "$node" "$username"
    log "Node '${node}' tainted — no new workloads will schedule here until session is stopped"
  fi

  echo
  echo -e "${BOLD}${GREEN}Session '${username}' is ready${NC}"
  echo -e "  Node:       ${node}"
  echo -e "  Image:      ${SESSION_IMAGE}"
  [[ -n "$node" ]] && echo -e "  Exclusive:  ${YELLOW}node tainted — other workloads blocked${NC}"
  echo
  echo -e "  ${BOLD}Connect:${NC}  $0 connect ${username}"
  echo -e "  ${BOLD}Stop:${NC}     $0 stop ${username}"
  echo
  echo "  Hardware inside the session:"
  echo "    GPU  — /dev/dri/renderD128      (Adreno 643L, OpenCL + Vulkan)"
  echo "    NPU  — /dev/fastrpc-cdsp        (Hexagon HTP, QNN)"
  echo "    VPU  — /dev/video32 /video33    (msm_vidc H.264/H.265)"
  echo "    DSP  — /dev/fastrpc-adsp-secure (ADSP)"
  if [[ "$cpu_type" == "all" ]]; then
    echo "    CPU  — all 8 cores (Kryo 670: 4×A55 Silver + 3×A78 Gold + 1×A78 Gold+)"
  else
    echo "    CPU  — ${cpu_type} only: $(cpu_type_description "$cpu_type")"
    echo -e "           ${YELLOW}(taskset -c ${cpu_cores} applied on connect)${NC}"
  fi
  if [[ -n "$BENCHMARK_DIR" ]]; then
    echo "  Benchmark:  /benchmark/build/hw_bench"
  fi
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

  # Read the CPU affinity stored at session-start time
  local cpu_type cpu_cores
  cpu_type=$("$KUBECTL" get pod "$pod" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.annotations.rubikpi\.ai/cpu-type}' 2>/dev/null || echo "all")
  cpu_cores=$("$KUBECTL" get pod "$pod" -n "$NAMESPACE" \
    -o jsonpath='{.metadata.annotations.rubikpi\.ai/cpu-cores}' 2>/dev/null || echo "0-7")
  cpu_type="${cpu_type:-all}"
  cpu_cores="${cpu_cores:-0-7}"

  info "Connecting to session '${username}'..."
  if [[ "$cpu_type" != "all" ]]; then
    info "CPU affinity: ${cpu_type} — pinning shell to cores ${cpu_cores} via taskset"
  fi
  echo -e "(Type ${BOLD}exit${NC} or press Ctrl-D to disconnect without stopping the session)"
  echo

  if [[ "$cpu_type" == "all" ]]; then
    exec "$KUBECTL" exec -it "$pod" -n "$NAMESPACE" -- bash
  else
    # taskset -c pins the exec'd bash process and all its children to the
    # specified CPU set.  The process's affinity mask is inherited by every
    # subprocess spawned from this shell (compilers, inference runtimes, etc.).
    exec "$KUBECTL" exec -it "$pod" -n "$NAMESPACE" -- taskset -c "$cpu_cores" bash
  fi
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
  printf "  %-20s %-30s %-10s %-20s %s\n" \
    "────────────────────" "──────────────────────────────" \
    "──────────" "────────────────────" "───"

  while IFS= read -r line; do
    local user pod status node ts
    read -r user pod status node ts <<< "$line"

    local status_col
    case "$status" in
      Running) status_col="${GREEN}Running${NC}" ;;
      Pending) status_col="${YELLOW}Pending${NC}" ;;
      *)       status_col="${RED}${status}${NC}" ;;
    esac

    # Check if the node has the exclusive taint for this session
    local taint_info=""
    if [[ -n "$node" && "$node" != "<none>" ]]; then
      local taint
      taint=$("$KUBECTL" get node "$node" \
        -o jsonpath="{.spec.taints[?(@.key==\"${SESSION_TAINT_KEY}\")].value}" \
        2>/dev/null || echo "")
      [[ -n "$taint" ]] && taint_info=" ${YELLOW}[exclusive]${NC}"
    fi

    local age="?"
    if [[ -n "$ts" ]] && command -v date &>/dev/null; then
      local now start elapsed
      now=$(date +%s 2>/dev/null || echo 0)
      start=$(date -d "$ts" +%s 2>/dev/null || echo "$now")
      elapsed=$(( now - start ))
      if   (( elapsed < 3600  )); then age="$((elapsed / 60))m"
      elif (( elapsed < 86400 )); then age="$((elapsed / 3600))h"
      else age="$((elapsed / 86400))d"
      fi
    fi

    printf "  %-20s %-30s " "$user" "$pod"
    echo -e "${status_col}${taint_info}"
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

  # Get the node BEFORE deleting the pod so we can untaint it
  local node
  node=$(pod_node "$pod")

  info "Stopping session '${username}'..."
  "$KUBECTL" delete pod "$pod" -n "$NAMESPACE" --grace-period=5

  # Remove exclusive taint from the node
  if [[ -n "$node" ]]; then
    info "Removing exclusive-session taint from node '${node}'..."
    untaint_node "$node"
    log "Node '${node}' is available again"
  fi

  log "Session '${username}' stopped"
  echo
  warn "Note: files saved to /root inside the session persist at:"
  echo  "  /var/lib/rubikpi-sessions/${username}/ on the node"
}

# ── untaint ────────────────────────────────────────────────────────────────────
# Removes orphaned session taints (e.g. after a pod was killed externally).
cmd_untaint() {
  local all=false
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --all) all=true; shift ;;
      *) warn "Unknown argument: $1"; shift ;;
    esac
  done

  # Find all nodes with the session taint
  local tainted_nodes
  tainted_nodes=$("$KUBECTL" get nodes \
    -o jsonpath="{range .items[*]}{.metadata.name}{'\t'}{range .spec.taints[?(@.key==\"${SESSION_TAINT_KEY}\")]}{.value}{end}{'\n'}{end}" \
    2>/dev/null | grep -v '^$' || true)

  if [[ -z "$tainted_nodes" ]]; then
    log "No nodes with session taints found."
    return 0
  fi

  echo "Nodes with active session taints:"
  while IFS=$'\t' read -r node taint_val; do
    echo "  $node  →  session=${taint_val}"
    # Check if the session pod is still running
    local pod_exists=false
    if [[ -n "$taint_val" ]]; then
      local pod_check
      pod_check=$(pod_name "$taint_val")
      "$KUBECTL" get pod "$pod_check" -n "$NAMESPACE" &>/dev/null && pod_exists=true || true
    fi

    if [[ "$pod_exists" == "true" ]]; then
      warn "  → Session pod still running — use 'stop ${taint_val}' to clean up properly"
    elif [[ "$all" == "true" || -z "$taint_val" ]]; then
      info "  → Removing orphaned taint from ${node}..."
      untaint_node "$node"
      log "  → Taint removed from ${node}"
    else
      warn "  → Session pod gone but taint remains — run '$0 untaint --all' to clean up"
    fi
  done <<< "$tainted_nodes"
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

# ── usage ───────────────────────────────────────────────────────────────────────
usage() {
  cat <<EOF

${BOLD}Rubik Pi 3 — Interactive Hardware Session Manager${NC}

USAGE
  $0 start   <username> [--node <nodename>] [--cpu-type <type>]
  $0 connect <username>
  $0 list
  $0 stop    <username>
  $0 logs    <username>
  $0 untaint [--all]

CPU AFFINITY  (--cpu-type)
  Pin the interactive shell (and all programs it spawns) to one cluster:

    silver    Cortex-A55  CPUs 0-3  efficiency cores  (1.96 GHz)
    gold      Cortex-A78  CPUs 4-6  performance cores  (2.40 GHz)
    gold-plus Cortex-A78  CPU  7    prime / boost core  (2.71 GHz)
    gold-all              CPUs 4-7  gold + gold-plus combined
    all                   CPUs 0-7  no affinity (default)

  Implemented via taskset(1) applied to the exec'd bash on 'connect'.
  The affinity is inherited by every subprocess in the shell.

EXCLUSIVE ACCESS
  Each session taints its Pi node with:
    ${SESSION_TAINT_KEY}=<username>:NoSchedule
  This prevents any new workload from scheduling on that node for the
  session's lifetime.  The taint is removed automatically on 'stop'.
  Existing DaemonSet pods (device plugin, etc.) are not affected.

HARDWARE INSIDE SESSIONS
  GPU   /dev/dri/renderD128           Adreno 643L (OpenCL, Vulkan)
  NPU   /dev/fastrpc-cdsp             Hexagon HTP (QNN HTP backend)
  VPU   /dev/video32, /dev/video33    msm_vidc (H.264/H.265 encode+decode)
  DSP   /dev/fastrpc-adsp-secure      ADSP
  CPU   8 cores                        Kryo 670 (4×A55 Silver + 3×A78 Gold + 1×A78 Gold+)

SDKS AVAILABLE IN SESSIONS (from host /usr/lib)
  OpenCL  — libOpenCL.so.1, libOpenCL_adreno.so.1 (GPU), POCL (CPU)
  QNN     — libQnnHtp.so (NPU), libQnnCpu.so, libQnnGpu.so
  FastRPC — libcdsprpc.so, libadsprpc.so
  V4L2    — v4l2-ctl, gst-launch-1.0

BENCHMARK
  Run /benchmark/build/hw_bench inside any session to test all subsystems.

ENVIRONMENT
  SESSION_IMAGE    Container image (default: ubuntu:24.04)
  SESSION_CPU_LIM  CPU cores limit per session (default: 6)
  SESSION_MEM_LIM  Memory limit per session (default: 8Gi)
  BENCHMARK_DIR    Path to benchmarks directory (default: repo/benchmarks)
  KUBECONFIG       Path to kubeconfig (default: /etc/rancher/rke2/rke2.yaml)

EXAMPLES
  # Start a session (scheduler picks the node, all cores)
  $0 start alice

  # Start a session pinned to Gold performance cores only
  $0 start alice --cpu-type gold

  # Start a session pinned to the single Gold+ prime core
  $0 start alice --cpu-type gold-plus

  # Start a session pinned to Silver efficiency cores only
  $0 start alice --cpu-type silver

  # Pin to specific Pi node + Gold cores
  $0 start alice --node rubikpi-3 --cpu-type gold

  # Connect (drops into bash; taskset is applied automatically if cpu-type was set)
  $0 connect alice

  # Run the hardware benchmark immediately after connecting
  #   (inside the pod):  /benchmark/build/hw_bench

  # List all sessions (shows [exclusive] if taint is active)
  $0 list

  # Stop a session and release the node
  $0 stop alice

  # Clean up orphaned taints after external pod deletion
  $0 untaint --all

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
    untaint) cmd_untaint "$@" ;;
    logs)    cmd_logs    "$@" ;;
    help|--help|-h|"") usage ;;
    *) err "Unknown command: ${cmd}. Run '$0 help' for usage." ;;
  esac
}

main "$@"
