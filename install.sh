#!/usr/bin/env bash
# Rubik Pi 3 — RKE2 Kubernetes Cluster Installer
#
# Usage:
#   Init node (first Pi, bootstraps the cluster):
#     sudo [METALLB_RANGE="192.168.1.200-192.168.1.220"] ./install.sh
#
#   Join node (all subsequent Pis — worker by default):
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
#   Recover a broken joined node by rediscovering the cluster:
#     sudo ./install.sh --retry
#
# Environment variables:
#   CLUSTER_SERVER           — manual join server override
#   CLUSTER_TOKEN            — manual join token override
#   CLUSTER_ROLE             — join role override: "agent" (default) or "server"
#   METALLB_RANGE            — IP range for MetalLB (init node only)
#   AUTOJOIN_ADVERTISE_TOKEN — init-node discovery policy override ("yes" or "no")
#   RANCHER_PASSWORD         — Rancher bootstrap password (default: rubikpi-admin)
#   INSTALL_VERBOSE          — "1" = stream full command output during install
# CLI flags:
#   --retry                  — force joined-node rediscovery instead of trusting local join endpoint state

set -euo pipefail

# ── Colours ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
BLUE='\033[0;34m'; BOLD='\033[1m'; NC='\033[0m'

log()  { echo -e "${GREEN}[✓]${NC} $*"; }
info() { echo -e "${BLUE}[→]${NC} $*"; }
warn() { echo -e "${YELLOW}[!]${NC} $*"; }
err()  { echo -e "${RED}[✗]${NC} $*" >&2; exit 1; }
step() { echo -e "\n${BOLD}${BLUE}── $* ──${NC}"; }

run_with_progress() {
  local description="$1"
  local heartbeat="$2"
  shift 2

  if [[ "${INSTALL_VERBOSE}" == "1" ]]; then
    info "${description}"
    "$@"
    return
  fi

  local log_file pid status start elapsed spinner='-\|/' idx=0
  log_file="$(mktemp /tmp/rubik-install.XXXXXX)"
  "$@" >"${log_file}" 2>&1 &
  pid=$!
  start=$(date +%s)

  while kill -0 "${pid}" 2>/dev/null; do
    elapsed=$(( $(date +%s) - start ))
    printf "\r${BLUE}[→]${NC} %s (%ss) %s" "${heartbeat}" "${elapsed}" "${spinner:${idx}:1}"
    idx=$(( (idx + 1) % 4 ))
    sleep 2
  done

  wait "${pid}"
  status=$?
  printf "\r\033[K"

  if [[ "${status}" -ne 0 ]]; then
    warn "${description} failed — showing captured output"
    sed 's/^/    /' "${log_file}" >&2 || true
    rm -f "${log_file}"
    return "${status}"
  fi

  rm -f "${log_file}"
  log "${description} complete"
}

run_shell_with_progress() {
  local description="$1"
  local heartbeat="$2"
  local command="$3"

  if [[ "${INSTALL_VERBOSE}" == "1" ]]; then
    info "${description}"
    bash -lc "set -euo pipefail; ${command}"
    return
  fi

  local log_file pid status start elapsed spinner='-\|/' idx=0
  log_file="$(mktemp /tmp/rubik-install.XXXXXX)"
  bash -lc "set -euo pipefail; ${command}" >"${log_file}" 2>&1 &
  pid=$!
  start=$(date +%s)

  while kill -0 "${pid}" 2>/dev/null; do
    elapsed=$(( $(date +%s) - start ))
    printf "\r${BLUE}[→]${NC} %s (%ss) %s" "${heartbeat}" "${elapsed}" "${spinner:${idx}:1}"
    idx=$(( (idx + 1) % 4 ))
    sleep 2
  done

  wait "${pid}"
  status=$?
  printf "\r\033[K"

  if [[ "${status}" -ne 0 ]]; then
    warn "${description} failed — showing captured output"
    sed 's/^/    /' "${log_file}" >&2 || true
    rm -f "${log_file}"
    return "${status}"
  fi

  rm -f "${log_file}"
  log "${description} complete"
}

wait_status() {
  local attempt="$1"
  local max="$2"
  local message="$3"

  if [[ "${INSTALL_VERBOSE}" == "1" || "${attempt}" -eq 1 || $(( attempt % 3 )) -eq 0 ]]; then
    info "${message} (attempt ${attempt}/${max})"
  fi
}

# ── Configuration ──────────────────────────────────────────────────────────────
CLUSTER_SERVER="${CLUSTER_SERVER:-}"
CLUSTER_TOKEN="${CLUSTER_TOKEN:-}"
CLUSTER_ROLE="${CLUSTER_ROLE:-}"
METALLB_RANGE="${METALLB_RANGE:-}"
AUTOJOIN_ADVERTISE_TOKEN="${AUTOJOIN_ADVERTISE_TOKEN:-}"
RANCHER_PASSWORD="${RANCHER_PASSWORD:-rubikpi-admin}"
INSTALL_VERBOSE="${INSTALL_VERBOSE:-0}"
RETRY_JOIN=0
LAST_DISCOVERY_STATE=""

APT_INSTALL_FLAGS=(-y -qq)
APT_UPDATE_FLAGS=(-qq)
if [[ "${INSTALL_VERBOSE}" == "1" ]]; then
  APT_INSTALL_FLAGS=(-y)
  APT_UPDATE_FLAGS=()
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RKE2_CONFIG_DIR="/etc/rancher/rke2"
RKE2_DATA_DIR="/var/lib/rancher/rke2"
KUBECONFIG_PATH="${RKE2_CONFIG_DIR}/rke2.yaml"
RKE2_KUBECTL="${RKE2_DATA_DIR}/bin/kubectl"
CLUSTER_DISCOVERY_HELPERS="${SCRIPT_DIR}/scripts/cluster-discovery.sh"
CLUSTER_DISCOVERY_INSTALL_BIN="/usr/local/bin/rubik-cluster-discovery"
CLUSTER_DISCOVERY_SERVICE_SRC="${SCRIPT_DIR}/manifests/rubik-cluster-advertise.service"
CLUSTER_DISCOVERY_SERVICE_DST="/etc/systemd/system/rubik-cluster-advertise.service"
CLUSTER_DISCOVERY_ENV_DST="/etc/default/rubik-cluster-advertise"
CLUSTER_DISCOVERY_AVAHI_DST="/etc/avahi/services/rubik-cluster.service"
AUTOJOIN_MODE_PATH="${RKE2_CONFIG_DIR}/autojoin-mode"

if [[ -f "${CLUSTER_DISCOVERY_HELPERS}" ]]; then
  # shellcheck source=/dev/null
  . "${CLUSTER_DISCOVERY_HELPERS}"
fi

# ── Helpers ────────────────────────────────────────────────────────────────────
apt_update_cmd() {
  apt-get update "${APT_UPDATE_FLAGS[@]}"
}

apt_install_cmd() {
  NEEDRESTART_MODE=l apt-get install "${APT_INSTALL_FLAGS[@]}" "$@"
}

apt_remove_cmd() {
  NEEDRESTART_MODE=l apt-get remove "${APT_INSTALL_FLAGS[@]}" "$@"
}

apt_fix_cmd() {
  NEEDRESTART_MODE=l apt-get -f install "${APT_INSTALL_FLAGS[@]}"
}

parse_cli_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --retry)
        RETRY_JOIN=1
        shift
        ;;
      --help|-h)
        cat <<'EOF'
Usage: sudo ./install.sh [--retry]

  --retry    Force joined-node rediscovery and refresh the local join endpoint
             from LAN metadata instead of trusting the stored server address.
EOF
        exit 0
        ;;
      *)
        err "Unknown argument: $1"
        ;;
    esac
  done
}

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

# Returns the /24 prefix of an IP ("192.168.0")
ip_prefix() { echo "$1" | cut -d. -f1-3; }

# Returns the first IP in the current MetalLB pool (e.g. "192.168.70.200")
current_metallb_ip() {
  "${RKE2_KUBECTL}" get ipaddresspool rubikpi-pool -n metallb-system \
    -o jsonpath='{.spec.addresses[0]}' 2>/dev/null | cut -d- -f1
}

generate_token() {
  if command -v openssl &>/dev/null; then
    openssl rand -hex 32
  else
    tr -dc 'a-f0-9' < /dev/urandom | head -c 64
  fi
}

have_local_rke2_install() {
  [[ -d "${RKE2_DATA_DIR}" || -f "${RKE2_CONFIG_DIR}/config.yaml" ]]
}

read_rke2_config_value() {
  local key="$1"
  local config_file="${RKE2_CONFIG_DIR}/config.yaml"

  [[ -f "${config_file}" ]] || return 1

  awk -F': ' -v key="${key}" '
    $1 == key {
      value = $2
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^"/, "", value)
      gsub(/"$/, "", value)
      print value
      exit
    }
  ' "${config_file}"
}

detect_local_join_role() {
  if systemctl list-unit-files --type=service --full 2>/dev/null | awk '$1 == "rke2-agent.service" { found=1 } END { exit(found ? 0 : 1) }'; then
    echo "agent"
  else
    echo "server"
  fi
}

resolve_join_role() {
  case "${CLUSTER_ROLE:-}" in
    "")
      printf '%s\n' "agent"
      ;;
    agent|server)
      printf '%s\n' "${CLUSTER_ROLE}"
      ;;
    *)
      err "CLUSTER_ROLE must be 'agent' or 'server'."
      ;;
  esac
}

parse_discovery_record_field() {
  local record="$1"
  local field_name="$2"

  if declare -F extract_discovery_record_field >/dev/null 2>&1; then
    extract_discovery_record_field "${record}" "${field_name}"
    return
  fi

  printf '%s\n' "${record}" | awk -F';' -v key="${field_name}" '
    {
      for (i = 10; i <= NF; i++) {
        split($i, pair, "=")
        if (pair[1] == key) {
          value = substr($i, length(key) + 2)
          gsub(/^"/, "", value)
          gsub(/"$/, "", value)
          print value
          exit
        }
      }
    }
  '
}

parse_discovery_record_address() {
  local record="$1"
  printf '%s\n' "${record}" | awk -F';' '
    $1 == "=" {
      if ($8 == "IPv4" || $8 == "IPv6") {
        print $9
      } else {
        print $8
      }
      exit
    }
  '
}

parse_discovery_record_service_port() {
  local record="$1"
  local field_port=""
  field_port="$(printf '%s\n' "${record}" | awk -F';' '
    $1 == "=" {
      if ($8 == "IPv4" || $8 == "IPv6") {
        print $10
      } else {
        print $9
      }
      exit
    }
  ')"
  if [[ -n "${field_port}" ]]; then
    printf '%s\n' "${field_port}"
  else
    parse_discovery_record_field "${record}" "server_port"
  fi
}

format_endpoint_url() {
  local host="$1"
  local port="$2"

  if [[ "${host}" == *:* && "${host}" != \[*\] ]]; then
    printf 'https://[%s]:%s\n' "${host}" "${port}"
  else
    printf 'https://%s:%s\n' "${host}" "${port}"
  fi
}

inspect_discovery_candidate() {
  declare -F discover_cluster_records >/dev/null 2>&1 || {
    printf '%s\n' "unavailable"
    printf '\n'
    return 0
  }

  local records unique_records resolved_count record server_host server_port mode token
  if ! records="$(discover_cluster_records 2>/dev/null)"; then
    printf '%s\n' "runtime-failure"
    printf '\n'
    return 0
  fi

  if [[ -z "${records}" ]]; then
    printf '%s\n' "none"
    printf '\n'
    return 0
  fi

  if declare -F unique_discovery_records >/dev/null 2>&1; then
    unique_records="$(unique_discovery_records "${records}" || true)"
  else
    unique_records="$(printf '%s\n' "${records}" | awk -F';' '$1 == "=" { print }')"
  fi

  resolved_count="$(printf '%s\n' "${unique_records}" | awk 'NF { count++ } END { print count + 0 }')"

  if [[ "${resolved_count}" -eq 0 ]]; then
    printf '%s\n' "invalid"
    printf '\n'
    return 0
  fi

  if [[ "${resolved_count}" -gt 1 ]]; then
    printf '%s\n' "multiple"
    printf '\n'
    return 0
  fi

  record="$(printf '%s\n' "${unique_records}" | awk 'NF { print; exit }')"
  [[ -n "${record}" ]] || {
    printf '%s\n' "invalid"
    printf '\n'
    return 0
  }

  server_host="$(parse_discovery_record_field "${record}" "server_host")"
  server_port="$(parse_discovery_record_field "${record}" "server_port")"
  mode="$(parse_discovery_record_field "${record}" "mode")"
  token="$(parse_discovery_record_field "${record}" "token")"

  if [[ -z "${server_host}" || -z "${server_port}" || -z "${mode}" ]]; then
    printf '%s\n' "invalid"
    printf '%s\n' "${record}"
    return 0
  fi

  case "${mode}" in
    open)
      if [[ -z "${token}" ]]; then
        printf '%s\n' "invalid"
        printf '%s\n' "${record}"
        return 0
      fi
      ;;
    manual)
      ;;
    *)
      printf '%s\n' "invalid"
      printf '%s\n' "${record}"
      return 0
      ;;
  esac

  printf '%s\n' "${mode}"
  printf '%s\n' "${record}"
}

discovered_join_candidate() {
  local discovery_info=()
  local discovery_state=""
  local record=""

  mapfile -t discovery_info < <(inspect_discovery_candidate)
  discovery_state="${discovery_info[0]:-invalid}"
  record="${discovery_info[1]:-}"

  case "${discovery_state}" in
    open|manual)
      printf '%s\n' "${record}"
      ;;
    *)
      return 1
      ;;
  esac
}

try_load_autojoin_from_discovery() {
  local discovery_info=()
  local discovery_state=""
  local record=""
  local server_host=""
  local server_address=""
  local server_port=""
  local token=""

  LAST_DISCOVERY_STATE=""
  AUTOJOIN_DISCOVERY_MODE=""

  mapfile -t discovery_info < <(inspect_discovery_candidate)
  discovery_state="${discovery_info[0]:-invalid}"
  record="${discovery_info[1]:-}"
  LAST_DISCOVERY_STATE="${discovery_state}"

  case "${discovery_state}" in
    open|manual)
      ;;
    *)
      return 1
      ;;
  esac

  server_host="$(parse_discovery_record_field "${record}" "server_host")"
  server_address="$(parse_discovery_record_address "${record}")"
  server_port="$(parse_discovery_record_service_port "${record}")"

  if [[ -z "${server_host}" || -z "${server_port}" ]]; then
    LAST_DISCOVERY_STATE="invalid"
    return 1
  fi

  if [[ -n "${server_address}" ]]; then
    CLUSTER_SERVER="$(format_endpoint_url "${server_address}" "${server_port}")"
  else
    CLUSTER_SERVER="$(format_endpoint_url "${server_host}" "${server_port}")"
  fi

  case "${discovery_state}" in
    open)
      token="$(parse_discovery_record_field "${record}" "token")"
      if [[ -z "${token}" ]]; then
        LAST_DISCOVERY_STATE="invalid"
        return 1
      fi
      CLUSTER_TOKEN="${token}"
      ;;
    manual)
      CLUSTER_TOKEN=""
      ;;
  esac

  AUTOJOIN_DISCOVERY_MODE="${discovery_state}"
  return 0
}

load_autojoin_from_discovery() {
  if try_load_autojoin_from_discovery; then
    return 0
  fi

  case "${LAST_DISCOVERY_STATE:-invalid}" in
    multiple)
      err "Multiple cluster discovery candidates found on the LAN. Refusing to guess; re-run with CLUSTER_SERVER and CLUSTER_TOKEN."
      ;;
    invalid)
      err "Discovered cluster advertisement is malformed or incomplete. Refusing to guess; fix discovery or re-run with CLUSTER_SERVER and CLUSTER_TOKEN."
      ;;
    runtime-failure)
      err "Cluster discovery browsing failed at runtime. Refusing to guess; fix Avahi/discovery or re-run with CLUSTER_SERVER and CLUSTER_TOKEN."
      ;;
    unavailable)
      err "Cluster discovery helper is unavailable. Refusing to guess; re-run with CLUSTER_SERVER and CLUSTER_TOKEN."
      ;;
    none)
      err "No cluster discovery candidate is currently visible on the LAN."
      ;;
    *)
      err "Unsupported discovery state: ${LAST_DISCOVERY_STATE:-unknown}"
      ;;
  esac
}

read_persisted_autojoin_mode() {
  local persisted_mode=""

  [[ -f "${AUTOJOIN_MODE_PATH}" ]] || return 1
  persisted_mode="$(tr -d '[:space:]' < "${AUTOJOIN_MODE_PATH}")"

  case "${persisted_mode}" in
    open|manual)
      printf '%s\n' "${persisted_mode}"
      ;;
    *)
      return 1
      ;;
  esac
}

read_key_value_file_value() {
  local file_path="$1"
  local key="$2"

  [[ -f "${file_path}" ]] || return 1

  awk -F'=' -v key="${key}" '
    $1 == key {
      value = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      gsub(/^"/, "", value)
      gsub(/"$/, "", value)
      print value
      exit
    }
  ' "${file_path}"
}

read_staged_autojoin_mode() {
  local staged_mode=""

  staged_mode="$(read_key_value_file_value "${CLUSTER_DISCOVERY_ENV_DST}" "DISCOVERY_ADVERTISE_MODE" || true)"

  case "${staged_mode}" in
    open|manual)
      printf '%s\n' "${staged_mode}"
      ;;
    *)
      return 1
      ;;
  esac
}

persist_autojoin_mode() {
  local mode="$1"

  case "${mode}" in
    open|manual)
      ;;
    *)
      err "Unsupported auto-join advertisement mode: ${mode}"
      ;;
  esac

  mkdir -p "${RKE2_CONFIG_DIR}"
  printf '%s\n' "${mode}" > "${AUTOJOIN_MODE_PATH}"
}

resolve_init_advertisement_mode() {
  local init_context="$1"
  local mode=""
  local prompt_reply=""

  case "${init_context}" in
    bootstrap|existing|repair)
      ;;
    *)
      err "Unsupported init advertisement context: ${init_context}"
      ;;
  esac

  if [[ -n "${AUTOJOIN_ADVERTISE_TOKEN}" ]]; then
    case "${AUTOJOIN_ADVERTISE_TOKEN}" in
      yes)
        mode="open"
        ;;
      no)
        mode="manual"
        ;;
      *)
        err "AUTOJOIN_ADVERTISE_TOKEN must be 'yes' or 'no'."
        ;;
    esac
  elif [[ "${init_context}" == "bootstrap" ]]; then
    [[ -t 0 && -t 1 ]] || \
      err "Fresh init bootstrap requires AUTOJOIN_ADVERTISE_TOKEN=yes|no when no interactive TTY is available."

    while true; do
      IFS= read -r -p "Advertise raw join token over LAN for zero-config auto-join? [Y/n] " prompt_reply || \
        err "Fresh init bootstrap requires AUTOJOIN_ADVERTISE_TOKEN=yes|no when interactive input is unavailable."

      case "${prompt_reply}" in
        ""|[Yy]|[Yy][Ee][Ss])
          mode="open"
          break
          ;;
        [Nn]|[Nn][Oo])
          mode="manual"
          break
          ;;
        *)
          warn "Please answer Y or n."
          ;;
      esac
    done
  else
    mode="$(read_persisted_autojoin_mode || true)"
    [[ -n "${mode}" ]] || mode="$(read_staged_autojoin_mode || true)"
    [[ -n "${mode}" ]] || mode="manual"
  fi

  persist_autojoin_mode "${mode}"
  printf '%s\n' "${mode}"
}

select_install_mode() {
  local discovery_info=()
  local discovery_state=""

  if [[ -n "${CLUSTER_SERVER}" || -n "${CLUSTER_TOKEN}" ]]; then
    [[ -n "${CLUSTER_SERVER}" && -n "${CLUSTER_TOKEN}" ]] || \
      err "Set both CLUSTER_SERVER and CLUSTER_TOKEN for manual join."
    echo "manual-join"
  elif have_local_rke2_install; then
    echo "repair"
  else
    mapfile -t discovery_info < <(inspect_discovery_candidate)
    discovery_state="${discovery_info[0]:-invalid}"

    case "${discovery_state}" in
      open)
        echo "auto-join-open"
        ;;
      manual)
        echo "auto-join-manual"
        ;;
      none)
        echo "init"
        ;;
      multiple)
        err "Multiple cluster discovery candidates found on the LAN. Refusing to guess; re-run with CLUSTER_SERVER and CLUSTER_TOKEN."
        ;;
      invalid)
        err "Discovered cluster advertisement is malformed or incomplete. Refusing to guess; fix discovery or re-run with CLUSTER_SERVER and CLUSTER_TOKEN."
        ;;
      runtime-failure)
        err "Cluster discovery browsing failed at runtime. Refusing to guess; fix Avahi/discovery or re-run with CLUSTER_SERVER and CLUSTER_TOKEN."
        ;;
      unavailable)
        err "Cluster discovery helper is unavailable. Refusing to guess; re-run with CLUSTER_SERVER and CLUSTER_TOKEN."
        ;;
      *)
        err "Unsupported discovery state: ${discovery_state}"
        ;;
    esac
  fi
}

# Resolve the cluster token to write into config.yaml.
#
# Priority order (most → least authoritative):
#   1. /var/lib/rancher/rke2/server/token  — written by RKE2 after first bootstrap;
#      format is "K1<CA-hash>::server:<password>".  We extract only <password>
#      because config.yaml needs the raw secret, not the full join-token.
#   2. Existing config.yaml token field      — preserves any user edits.
#   3. Fresh random token                    — only for a brand-new installation.
resolve_token() {
  local server_token_file="${RKE2_DATA_DIR}/server/token"
  local config_file="${RKE2_CONFIG_DIR}/config.yaml"

  if [[ -f "$server_token_file" ]]; then
    local full
    full=$(cat "$server_token_file")
    # Extract password portion from "K1<hash>::server:<password>" or "K1<hash>::agent:<password>"
    if [[ "$full" == *"::"* ]]; then
      echo "${full##*:}"
    else
      echo "$full"  # plain token already (no :: separator)
    fi
    return
  fi

  if [[ -f "$config_file" ]]; then
    local existing
    existing=$(grep -E '^token:' "$config_file" | awk '{print $2}' | tr -d '"' | head -1)
    if [[ -n "$existing" ]]; then
      echo "$existing"
      return
    fi
  fi

  generate_token
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

  # ── Ensure the standard Ubuntu ARM64 repos are present ───────────────────────
  # Some Rubik Pi board images ship without the standard Ubuntu sources
  # (ports.ubuntu.com), leaving only the Thundercomm / Canonical Qualcomm repos.
  # Without ubuntu-ports, fundamental packages like libatomic1, libgcc-s1, etc.
  # are missing and most subsequent apt-get calls fail.
  local ubuntu_sources="/etc/apt/sources.list.d/ubuntu.sources"
  if ! grep -q "ports.ubuntu.com" "$ubuntu_sources" 2>/dev/null && \
     ! grep -r "ports.ubuntu.com" /etc/apt/sources.list /etc/apt/sources.list.d/ &>/dev/null; then
    info "Standard Ubuntu ARM64 repos missing — adding ubuntu.sources"
    cat > "$ubuntu_sources" <<'SOURCES'
Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports
Suites: noble noble-updates noble-backports
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg

Types: deb
URIs: http://ports.ubuntu.com/ubuntu-ports
Suites: noble-security
Components: main universe restricted multiverse
Signed-By: /usr/share/keyrings/ubuntu-archive-keyring.gpg
SOURCES
    log "ubuntu.sources written — standard Ubuntu packages now available"
  fi

  # ── Repair any interrupted installs or held broken packages ───────────────
  # This is common on a fresh Rubik Pi image that had a partial update.
  run_with_progress "Repairing interrupted package state" "Repairing interrupted packages" \
    dpkg --configure -a || true
  run_with_progress "Repairing broken package dependencies" "Repairing package dependencies" \
    apt_fix_cmd || true

  # Remove any legacy apt pins or holds from previous installer versions that
  # may have been written to prevent linux-firmware from upgrading.  The correct
  # approach is the opposite: we NEED linux-firmware to upgrade so that
  # linux-firmware-dragonwing's "Depends: linux-firmware >= 0ubuntu2.23"
  # is satisfied — otherwise any package that touches this dependency chain
  # (libqnn1, libsnpe1, etc.) will fail to install.
  rm -f /etc/apt/preferences.d/rubikpi-firmware
  apt-mark unhold linux-firmware 2>/dev/null || true

  run_with_progress "Refreshing apt package indexes" "Refreshing package indexes" \
    apt_update_cmd

  # ── Linux firmware ─────────────────────────────────────────────────────────
  # linux-firmware-dragonwing (pre-installed on Rubik Pi) declares:
  #   Depends: linux-firmware (>= 0ubuntu2.23)
  # Fresh board images often have linux-firmware at an older version
  # (0ubuntu2.14) that doesn't satisfy this.  Upgrade it explicitly so the
  # dragonwing dependency is satisfied before we try to install any Qualcomm
  # SDK packages that transitively depend on this being resolved.
  run_with_progress "Installing linux-firmware" "Installing linux-firmware" \
    apt_install_cmd linux-firmware || \
    warn "linux-firmware upgrade failed — QNN/SNPE packages may not install"

  # Keep the board on the current qcom kernel line. We found rubik2 only gained
  # stable normal-user GPU OpenCL after moving from 1054 to the 1064 kernel.
  run_with_progress "Installing qcom kernel and board firmware" "Installing qcom kernel and board firmware" \
    apt_install_cmd linux-image-qcom linux-firmware-qcom-rubikpi3 || \
    warn "qcom kernel / board firmware upgrade failed — full GPU parity may require manual repair"

  # ── Qualcomm AI inference SDKs ─────────────────────────────────────────────
  # QNN and SNPE packages are installed one-by-one so that a single broken
  # or unavailable package doesn't block the rest of the stack.
  # QNN (Qualcomm Neural Network) — HTP/GPU/DSP/CPU inference backends.
  # SNPE (Snapdragon Neural Processing Engine) — legacy SDK, still widely used.
  local qnn_pkgs=(libqnn1 libqnn-dev qnn-tools)
  local snpe_pkgs=(libsnpe1 libsnpe-dev snpe-tools)
  for pkg in "${qnn_pkgs[@]}" "${snpe_pkgs[@]}"; do
    run_with_progress "Installing ${pkg}" "Installing ${pkg}" \
      apt_install_cmd "$pkg" || warn "Could not install ${pkg} — skipping"
  done

  # ── Adreno GPU OpenCL ICD ──────────────────────────────────────────────────
  # Provides libOpenCL_adreno.so, libadreno_utils.so, and the adreno.icd
  # entry that the OCL ICD loader uses to enumerate the Adreno GPU platform.
  # Older installer revisions could leave the generic ocl-icd loader installed.
  # That owned libOpenCL.so.1 and caused rubik2 to enumerate CPU-only OpenCL.
  run_with_progress "Removing conflicting generic OpenCL runtime" "Removing conflicting OpenCL runtime" \
    apt_remove_cmd ocl-icd-opencl-dev ocl-icd-libopencl1 clinfo || true
  run_with_progress "Reinstalling Adreno OpenCL userspace" "Reinstalling Adreno OpenCL userspace" \
    apt_install_cmd --reinstall qcom-adreno1 clinfo || true

  # ── FastRPC userspace libraries ────────────────────────────────────────────
  # libcdsprpc.so / libadsprpc.so — needed to open RPC sessions to CDSP
  # (Hexagon NPU/CDSP) and ADSP from userspace.  The kernel-side daemons
  # (cdsprpcd, adsprpcd) are pre-installed; ensure the userspace libs match.
  # qcom-property-vault — provides libpropertyvault.so which the Adreno OCL
  # ICD uses for Android-style system properties on Linux.
  for pkg in qcom-fastrpc1 qcom-fastrpc-dev qcom-property-vault; do
    run_with_progress "Installing ${pkg}" "Installing ${pkg}" \
      apt_install_cmd "$pkg" || warn "Could not install ${pkg} — skipping"
  done

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
  # Install headers only; avoid the generic ICD runtime that displaced Adreno.
  run_with_progress "Installing CPU OpenCL tooling" "Installing CPU OpenCL tooling" \
    apt_install_cmd \
      pocl-opencl-icd \
      opencl-c-headers \
      opencl-headers \
      opencl-clhpp-headers \
      clinfo || true

  # ── V4L2 / GStreamer tools ─────────────────────────────────────────────────
  # v4l-utils — v4l2-ctl, v4l2-compliance: inspect and test video devices
  #              (msm_vidc VPU encoder at /dev/video32-33).
  # gstreamer1.0-tools + plugins-bad — gst-launch-1.0 pipeline tool and the
  #   v4l2h264enc element used to drive the VPU from scripts/containers.
  # The Qualcomm GStreamer plugins (gstreamer1.0-plugins-qcom-*) are already
  # pre-installed by the Thundercomm/Tangshan repos in the base image.
  run_with_progress "Installing V4L2 and GStreamer tooling" "Installing V4L2 and GStreamer tooling" \
    apt_install_cmd \
      v4l-utils \
      gstreamer1.0-tools \
      gstreamer1.0-plugins-bad || true

  # ── C++ build toolchain ────────────────────────────────────────────────────
  # Required to compile the hw_bench C++ benchmark on the node itself.
  # cmake ≥ 3.16, g++13, libdrm-dev for DRM/KMS device queries.
  run_with_progress "Installing C++ build tooling" "Installing C++ build tooling" \
    apt_install_cmd \
      cmake \
      build-essential \
      g++ \
      libdrm-dev || true

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

  # qcom-adreno1 does not reliably materialize the ICD file on every image, so
  # write it explicitly. Without this, clinfo and QNN can fall back to CPU-only.
  mkdir -p /etc/OpenCL/vendors
  printf '%s\n' "libOpenCL_adreno.so.1" > /etc/OpenCL/vendors/adreno.icd
  log "Ensured Adreno OpenCL ICD: /etc/OpenCL/vendors/adreno.icd"

  local boot_kernel=""
  boot_kernel=$(basename "$(readlink -f /boot/vmlinuz 2>/dev/null || true)" 2>/dev/null || true)
  boot_kernel="${boot_kernel#vmlinuz-}"
  if [[ -n "${boot_kernel}" && "${boot_kernel}" != "$(uname -r)" ]]; then
    warn "New qcom kernel installed (${boot_kernel}); reboot after install for full GPU/OpenCL parity"
  fi

  log "Qualcomm hardware SDK stack installed"
}

# ── System preparation (run on every node before RKE2) ────────────────────────
prepare_system() {
  step "Preparing system"

  export DEBIAN_FRONTEND=noninteractive
  run_with_progress "Refreshing apt package indexes" "Refreshing package indexes" \
    apt_update_cmd
  # open-iscsi + iscsid: required by Longhorn for block storage
  # nfs-common: required by Longhorn for backup NFS targets
  # util-linux: provides findmnt/blkid used by Longhorn
  # avahi-daemon + avahi-utils + libnss-mdns: advertise, browse, and resolve .local
  # discovery endpoints on fresh images without requiring manual NSS edits.
  run_with_progress "Installing base system packages" "Installing base system packages" \
    apt_install_cmd curl openssl open-iscsi nfs-common util-linux avahi-daemon avahi-utils libnss-mdns

  # Enable iscsid — Longhorn requires it to be running on every node
  systemctl enable iscsid 2>/dev/null || true
  systemctl start  iscsid 2>/dev/null || true
  log "iSCSI daemon enabled and started"

  # Avahi provides the LAN discovery runtime used by later auto-join tasks.
  systemctl enable avahi-daemon.service avahi-daemon.socket 2>/dev/null || true
  systemctl start avahi-daemon.socket 2>/dev/null || true
  systemctl start avahi-daemon.service 2>/dev/null || true
  log "Avahi runtime enabled and started"

  if declare -F ensure_local_mdns_resolution >/dev/null 2>&1; then
    ensure_local_mdns_resolution || warn "Could not update nsswitch.conf for .local name resolution"
  fi

  # Normal-user GPU OpenCL requires access to /dev/dri/renderD128. Fresh images
  # do not always place the invoking user into the render group.
  if getent group render >/dev/null 2>&1; then
    if [[ -n "${SUDO_USER:-}" && "${SUDO_USER}" != "root" ]]; then
      usermod -aG render "${SUDO_USER}" 2>/dev/null || warn "Could not add ${SUDO_USER} to render group"
      log "Ensured ${SUDO_USER} belongs to the render group"
    fi
  fi

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
    ufw allow 5353/udp  comment 'mDNS / Avahi discovery'          2>/dev/null
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
    run_shell_with_progress "Installing Helm" "Installing Helm" \
      "curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash -s -- --no-sudo 2>/dev/null || curl -fsSL https://raw.githubusercontent.com/helm/helm/main/scripts/get-helm-3 | bash"
  else
    log "Helm $(helm version --short 2>/dev/null | grep -oP 'v[0-9.]+' | head -1) already installed"
  fi
}

# ── kubectl / kubeconfig setup ─────────────────────────────────────────────────
setup_kubectl() {
  step "Setting up kubectl"

  # Symlink kubectl from the RKE2 bundle — works on all node types
  if [[ ! -e /usr/local/bin/kubectl ]]; then
    ln -sf "${RKE2_KUBECTL}" /usr/local/bin/kubectl
  fi

  export KUBECONFIG="$KUBECONFIG_PATH"

  local home_dir
  home_dir=$(getent passwd ubuntu 2>/dev/null | cut -d: -f6 || echo "/home/ubuntu")

  if [[ -d "$home_dir" ]]; then
    # Agent nodes do not have a local kubeconfig (rke2-agent writes no server
    # credentials to disk).  Skip the copy but still add PATH for the binary.
    if [[ -f "$KUBECONFIG_PATH" ]]; then
      mkdir -p "${home_dir}/.kube"
      # Always overwrite so the file stays in sync after IP changes or cert
      # rotations — the RKE2 kubeconfig is not secret (it uses mTLS anyway).
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
      log "kubectl configured (KUBECONFIG=${KUBECONFIG_PATH})"
    else
      # Agent node: no server kubeconfig is generated locally.
      # Use kubectl from a server node, or copy its kubeconfig here manually:
      #   scp <server>:/etc/rancher/rke2/rke2.yaml ~/.kube/config
      #   sed -i 's/127.0.0.1/<server-ip>/' ~/.kube/config
      local bashrc="${home_dir}/.bashrc"
      if ! grep -q "rancher/rke2/bin" "$bashrc" 2>/dev/null; then
        {
          echo ""
          echo "# RKE2 Kubernetes (agent node — kubectl binary only)"
          echo "export PATH=\$PATH:/var/lib/rancher/rke2/bin"
        } >> "$bashrc"
      fi
      warn "Agent node: kubectl binary linked but no local kubeconfig."
      warn "Copy kubeconfig from a server node to use kubectl here:"
      warn "  scp <server>:/etc/rancher/rke2/rke2.yaml ~/.kube/config"
      warn "  sed -i 's/127.0.0.1/<server-ip>/' ~/.kube/config"
    fi
  fi
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
    wait_status "$i" "$max" "Still waiting for node '${node}' to report Ready"
    sleep 5
  done
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
    if [[ "${INSTALL_VERBOSE}" == "1" || "${i}" -eq 1 || $(( i % 3 )) -eq 0 ]]; then
      info "Still waiting for LoadBalancer IP on ${ns}/${svc} (attempt ${i}/${max})" >&2
    fi
    sleep 5
  done
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
    wait_status "$i" "$max" "Still waiting for pods in ${ns} matching ${selector} (${running}/${total} running)"
    sleep 5
  done
  warn "Pods in ${ns} (${selector}) not all ready after timeout — continuing"
}

# ── RKE2 Installation ──────────────────────────────────────────────────────────
install_rke2() {
  local rke2_type="$1"   # server or agent

  if systemctl is-active --quiet "rke2-${rke2_type}" 2>/dev/null; then
    log "rke2-${rke2_type} is already running — skipping RKE2 install"
    return 0
  fi

  run_shell_with_progress "Downloading and installing RKE2 (${rke2_type})" "Installing RKE2 (${rke2_type})" \
    "curl -sfL https://get.rke2.io | INSTALL_RKE2_TYPE='${rke2_type}' sh -"

  systemctl enable "rke2-${rke2_type}"
  run_with_progress "Starting rke2-${rke2_type}" "Starting rke2-${rke2_type}" \
    systemctl start "rke2-${rke2_type}"

  log "rke2-${rke2_type} started"
}

# ── Helm chart installs (init node only) ───────────────────────────────────────
# All installs use `helm upgrade --install` so re-runs are fully idempotent.

install_metallb() {
  local range="$1"
  step "Installing MetalLB"

  run_with_progress "Adding MetalLB Helm repo" "Adding MetalLB Helm repo" \
    helm repo add metallb https://metallb.github.io/metallb --force-update
  run_with_progress "Updating MetalLB Helm repo" "Updating MetalLB Helm repo" \
    helm repo update metallb
  run_with_progress "Installing MetalLB chart" "Installing MetalLB chart" \
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
  log "MetalLB pool configured: ${range}"
}

update_metallb_pool() {
  local range="$1"
  info "Updating MetalLB IP pool to: ${range}"
  "$RKE2_KUBECTL" patch ipaddresspool rubikpi-pool -n metallb-system --type='json' \
    -p="[{\"op\":\"replace\",\"path\":\"/spec/addresses/0\",\"value\":\"${range}\"}]"
  log "MetalLB pool updated"
}

# Remove any stale externalIPs from the traefik service so only MetalLB's
# dynamically assigned IP is shown.
clean_traefik_external_ips() {
  local current_ext
  current_ext=$("$RKE2_KUBECTL" get svc traefik -n traefik \
    -o jsonpath='{.spec.externalIPs[*]}' 2>/dev/null || true)
  if [[ -n "$current_ext" ]]; then
    info "Removing stale externalIPs from traefik service: ${current_ext}"
    "$RKE2_KUBECTL" get svc traefik -n traefik -o json | \
      python3 -c "
import json,sys
svc=json.load(sys.stdin)
svc['spec']['externalIPs']=[]
svc['spec'].pop('loadBalancerIP',None)
print(json.dumps(svc))
" | "$RKE2_KUBECTL" apply -f - 2>/dev/null || true
  fi
}

install_traefik() {
  step "Installing Traefik"

  run_with_progress "Adding Traefik Helm repo" "Adding Traefik Helm repo" \
    helm repo add traefik https://traefik.github.io/charts --force-update
  run_with_progress "Updating Traefik Helm repo" "Updating Traefik Helm repo" \
    helm repo update traefik

  run_with_progress "Installing Traefik chart" "Installing Traefik chart" \
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

  run_with_progress "Adding cert-manager Helm repo" "Adding cert-manager Helm repo" \
    helm repo add jetstack https://charts.jetstack.io --force-update
  run_with_progress "Updating cert-manager Helm repo" "Updating cert-manager Helm repo" \
    helm repo update jetstack

  run_with_progress "Installing cert-manager chart" "Installing cert-manager chart" \
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
  # Always re-derive from the live MetalLB-assigned IP so that if the subnet
  # changed (and the pool was updated) the hostname stays correct.
  local rancher_hostname=""
  local traefik_ip
  traefik_ip=$(wait_for_lb_ip traefik traefik) || {
    warn "Could not obtain Traefik LoadBalancer IP — falling back to node IP"
    traefik_ip="$node_ip"
  }
  rancher_hostname="rancher.${traefik_ip}.nip.io"
  # Cache for informational purposes; always recompute from live IP on next run.
  echo "$rancher_hostname" > "${RKE2_CONFIG_DIR}/rancher-hostname"

  log "Rancher hostname: ${rancher_hostname}"

  run_with_progress "Adding Rancher Helm repo" "Adding Rancher Helm repo" \
    helm repo add rancher-stable https://releases.rancher.com/server-charts/stable --force-update
  run_with_progress "Updating Rancher Helm repo" "Updating Rancher Helm repo" \
    helm repo update rancher-stable

  run_with_progress "Installing Rancher chart" "Installing Rancher chart" \
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

  run_with_progress "Adding Longhorn Helm repo" "Adding Longhorn Helm repo" \
    helm repo add longhorn https://charts.longhorn.io --force-update
  run_with_progress "Updating Longhorn Helm repo" "Updating Longhorn Helm repo" \
    helm repo update longhorn

  # defaultReplicaCount=1: required for single-node — Longhorn won't schedule
  # volumes with replica count > number of nodes.
  run_with_progress "Installing Longhorn chart" "Installing Longhorn chart" \
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

install_cpu_topology_labeler() {
  step "Installing CPU topology labeler"

  local manifest="${SCRIPT_DIR}/manifests/cpu-topology-labeler.yaml"
  if [[ -f "$manifest" ]]; then
    "$RKE2_KUBECTL" apply -f "$manifest"
    log "CPU topology labeler applied (DaemonSet will label all Rubik nodes automatically)"
  else
    warn "manifests/cpu-topology-labeler.yaml not found — skipping"
  fi
}

label_node_cpu_topology() {
  # Label this node with its CPU core type assignments so session.sh and other
  # tools can discover which cpuset corresponds to each Kryo 670 cluster.
  # The QCS6490 topology is fixed on all Rubik Pi 3 boards — three frequency
  # domains map directly to the three Kubernetes "cpu-type" values:
  #
  #   rubikpi.ai/cpu-silver-cores    = "0-3"   Cortex-A55  1.96 GHz  efficiency
  #   rubikpi.ai/cpu-gold-cores      = "4-6"   Cortex-A78  2.40 GHz  performance
  #   rubikpi.ai/cpu-gold-plus-cores = "7"     Cortex-A78  2.71 GHz  prime
  step "Labelling node with CPU core topology"
  local node
  node=$(hostname)

  # Agent nodes have no local kubeconfig — the RKE2 kubectl binary exists but
  # KUBECONFIG isn't set, so the label must be applied from the control plane.
  # We try with whatever KUBECONFIG is available; if it fails we print the
  # command to run from the init node instead of aborting.
  if "$RKE2_KUBECTL" label node "$node" \
      rubikpi.ai/cpu-silver-cores="0-3" \
      rubikpi.ai/cpu-gold-cores="4-6" \
      rubikpi.ai/cpu-gold-plus-cores="7" \
      --overwrite 2>/dev/null; then
    log "CPU topology labels applied to node '${node}'"
  else
    warn "Could not label node locally (agent node has no kubeconfig)."
    warn "Run this from the control-plane node (rubikpi):"
    warn "  kubectl label node ${node} \\"
    warn "    rubikpi.ai/cpu-silver-cores=0-3 \\"
    warn "    rubikpi.ai/cpu-gold-cores=4-6 \\"
    warn "    rubikpi.ai/cpu-gold-plus-cores=7 --overwrite"
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

patch_coredns_for_session_taint() {
  step "Patching CoreDNS for session-taint tolerance"

  local deploy="rke2-coredns-rke2-coredns"
  local namespace="kube-system"

  if ! "$RKE2_KUBECTL" get deployment "$deploy" -n "$namespace" >/dev/null 2>&1; then
    warn "CoreDNS deployment not found yet — skipping session-taint patch"
    return 0
  fi

  local existing=""
  existing=$("$RKE2_KUBECTL" get deployment "$deploy" -n "$namespace" \
    -o jsonpath='{range .spec.template.spec.tolerations[*]}{.key}{"="}{.effect}{"\n"}{end}' 2>/dev/null || true)

  if printf '%s\n' "$existing" | awk '$0 == "rubikpi.ai/exclusive-session=NoSchedule" { found=1 } END { exit(found ? 0 : 1) }'; then
    log "CoreDNS already tolerates the session taint"
    return 0
  fi

  "$RKE2_KUBECTL" patch deployment "$deploy" -n "$namespace" --type='json' -p='[
    {"op":"add","path":"/spec/template/spec/tolerations/-","value":{"key":"rubikpi.ai/exclusive-session","operator":"Exists","effect":"NoSchedule"}}
  ]' >/dev/null

  log "CoreDNS patched to tolerate rubikpi.ai/exclusive-session"
}

# ── Network-reconcile service ──────────────────────────────────────────────────
# Installs a lightweight systemd service that runs on every boot (after the
# network comes up) to detect node IP changes and automatically:
#   • update config.yaml tls-san
#   • run rke2 server --cluster-reset when the etcd peer URL is stale
#   • update the MetalLB IPAddressPool to the new subnet
#   • wait for Traefik to receive a new LoadBalancer IP
#   • update the Rancher Helm release with a new nip.io hostname
#
# This is what makes the cluster survive being moved between networks.
install_network_reconcile() {
  step "Installing network-reconcile service"

  local script_src="${SCRIPT_DIR}/scripts/network-reconcile.sh"
  local service_src="${SCRIPT_DIR}/manifests/rubik-network-reconcile.service"
  local script_dst="/usr/local/bin/rubik-network-reconcile"
  local service_dst="/etc/systemd/system/rubik-network-reconcile.service"

  if [[ ! -f "$script_src" ]]; then
    warn "scripts/network-reconcile.sh not found — skipping"
    return 0
  fi

  install -m 755 "$script_src" "$script_dst"

  if [[ -f "$service_src" ]]; then
    install -m 644 "$service_src" "$service_dst"
  else
    # Write the unit inline if the file wasn't shipped
    cat > "$service_dst" <<'UNIT'
[Unit]
Description=Rubik Pi — Kubernetes network reconciliation
After=network-online.target
Wants=network-online.target
Before=rke2-server.service rke2-agent.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/local/bin/rubik-network-reconcile
StandardOutput=journal
StandardError=journal
SyslogIdentifier=rubik-net-reconcile
TimeoutStartSec=1200

[Install]
WantedBy=multi-user.target
UNIT
  fi

  systemctl daemon-reload
  systemctl enable rubik-network-reconcile
  # rke2-server stays enabled; the Before= ordering in the unit file ensures
  # the reconcile service always runs first so any IP-change fix is applied
  # before RKE2 tries to start.
  log "Network-reconcile service installed and enabled"
}

install_cluster_discovery_runtime() {
  step "Installing cluster discovery runtime"

  if [[ ! -f "${CLUSTER_DISCOVERY_HELPERS}" ]]; then
    warn "scripts/cluster-discovery.sh not found — skipping"
    return 0
  fi

  install -m 755 "${CLUSTER_DISCOVERY_HELPERS}" "${CLUSTER_DISCOVERY_INSTALL_BIN}"
  if declare -F ensure_avahi_physical_interface_binding >/dev/null 2>&1; then
    ensure_avahi_physical_interface_binding || warn "Could not bind Avahi to the detected physical interface"
  fi
  log "Cluster discovery helper installed for LAN browse/reconcile"
}

install_cluster_discovery() {
  local advertise_mode="${1:-manual}"
  local advertise_token="${2:-}"
  step "Installing cluster discovery scaffolding"

  install_cluster_discovery_runtime

  if [[ ! -f "${CLUSTER_DISCOVERY_SERVICE_SRC}" ]]; then
    warn "manifests/rubik-cluster-advertise.service not found — skipping advertisement activation"
    return 0
  fi

  local short_hostname
  short_hostname=$(hostname -s 2>/dev/null || hostname)

  case "${advertise_mode}" in
    open)
      [[ -n "${advertise_token}" ]] || err "Open auto-join advertisement requires a token."
      ;;
    manual)
      advertise_token=""
      ;;
    *)
      err "Unsupported cluster discovery advertisement mode: ${advertise_mode}"
      ;;
  esac

  install -m 644 "${CLUSTER_DISCOVERY_SERVICE_SRC}" "${CLUSTER_DISCOVERY_SERVICE_DST}"

  mkdir -p "$(dirname "${CLUSTER_DISCOVERY_ENV_DST}")"
  cat > "${CLUSTER_DISCOVERY_ENV_DST}" <<EOF
# Rubik cluster advertisement policy.
DISCOVERY_ADVERTISE_MODE=${advertise_mode}
DISCOVERY_ADVERTISE_TOKEN=${advertise_token}
DISCOVERY_ADVERTISE_HOSTNAME=${short_hostname}
DISCOVERY_AVAHI_SERVICE_PATH=${CLUSTER_DISCOVERY_AVAHI_DST}
EOF

  DISCOVERY_ADVERTISE_MODE="${advertise_mode}" \
  DISCOVERY_ADVERTISE_TOKEN="${advertise_token}" \
  DISCOVERY_ADVERTISE_HOSTNAME="${short_hostname}" \
  DISCOVERY_AVAHI_SERVICE_PATH="${CLUSTER_DISCOVERY_AVAHI_DST}" \
    "${CLUSTER_DISCOVERY_INSTALL_BIN}" advertise-service >/dev/null

  systemctl daemon-reload
  systemctl enable rubik-cluster-advertise
  systemctl start rubik-cluster-advertise
  systemctl reload-or-restart avahi-daemon
  log "Cluster discovery advertisement mode: ${advertise_mode}"
  log "Cluster discovery helper and Avahi advertisement runtime installed"
}

# ── IP-change recovery ─────────────────────────────────────────────────────────
# When a node's IP address changes after the cluster was bootstrapped, the etcd
# peer URL stored inside the etcd database becomes stale.  rke2-server then
# refuses to start with:
#   "this server is not a member of the etcd cluster.
#    Found [node=https://<old-ip>:2380], expect: node=https://<new-ip>:2380"
#
# This function detects that mismatch and runs `rke2 server --cluster-reset`
# to re-elect this node as the sole etcd member using its current IP — without
# wiping any cluster data.
fix_ip_change() {
  local current_ip="$1"
  local etcd_data_dir="${RKE2_DATA_DIR}/server/db/etcd"

  # Nothing to fix if there is no etcd data yet.
  [[ -d "$etcd_data_dir" ]] || return 0

  # Read the peer URL from etcd's stored member list.  The file lives at a
  # fixed path inside the etcd WAL/snap directory written by etcd itself.
  # We search for the address pattern rather than parsing binary WAL files.
  local stored_ip
  stored_ip=$(strings "${etcd_data_dir}/member/snap/db" 2>/dev/null \
    | grep -oP 'https?://\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(?=:2380)' \
    | head -1 || true)

  # Fall back to scanning member directory if snap/db is absent or unreadable.
  if [[ -z "$stored_ip" ]]; then
    stored_ip=$(strings "${etcd_data_dir}/member/wal/"*.wal 2>/dev/null \
      | grep -oP 'https?://\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(?=:2380)' \
      | grep -v "^127\." | head -1 || true)
  fi

  if [[ -n "$stored_ip" && "$stored_ip" != "$current_ip" ]]; then
    warn "Node IP changed: etcd has ${stored_ip}, current IP is ${current_ip}"
    warn "Running cluster-reset to update etcd peer URL (data is preserved)..."

    systemctl stop rke2-server 2>/dev/null || true
    sleep 2

    # Run the reset in the background with a timeout; it starts etcd, updates
    # the member URL, and then exits when the API server becomes ready.
    local reset_log
    reset_log=$(mktemp /tmp/rke2-cluster-reset.XXXXXX.log)
    timeout 120 rke2 server --cluster-reset >"$reset_log" 2>&1 &
    local reset_pid=$!

    info "Waiting for cluster-reset to complete (up to 120 s)..."
    local i
    for i in $(seq 1 24); do
      wait_status "$i" 24 "Still waiting for cluster-reset to finish"
      sleep 5
      if ! kill -0 "$reset_pid" 2>/dev/null; then
        break
      fi
      if grep -q "rke2 is up and running" "$reset_log" 2>/dev/null; then
        kill "$reset_pid" 2>/dev/null || true
        break
      fi
    done
    wait "$reset_pid" 2>/dev/null || true
    rm -f "$reset_log"

    log "Cluster-reset complete — etcd peer URL updated to ${current_ip}"
  elif [[ -z "$stored_ip" ]]; then
    info "Could not read stored etcd IP — skipping IP-change check"
  else
    log "Node IP matches etcd peer URL (${current_ip}) — no reset needed"
  fi
}

# ── Init mode ──────────────────────────────────────────────────────────────────
install_init() {
  local init_context="${1:-bootstrap}"
  local node_ip
  local autojoin_mode

  case "${init_context}" in
    bootstrap|existing|repair)
      ;;
    *)
      err "Unsupported install_init context: ${init_context}"
      ;;
  esac

  node_ip=$(detect_node_ip) || err "Cannot detect node IP — is the network configured?"
  log "Node IP: ${node_ip}"

  # Derive MetalLB range automatically from the current node IP.
  # Override with METALLB_RANGE env var if you need a specific range.
  if [[ -z "$METALLB_RANGE" ]]; then
    METALLB_RANGE=$(suggest_metallb_range "$node_ip")
    log "MetalLB IP range (auto-derived from node subnet): ${METALLB_RANGE}"
  else
    log "MetalLB IP range (from env): ${METALLB_RANGE}"
  fi

  # If MetalLB is already installed and its pool is in a different subnet,
  # update the pool now so the LB IP follows the node to the new subnet.
  if "$RKE2_KUBECTL" get ipaddresspool rubikpi-pool -n metallb-system &>/dev/null; then
    local current_pool_ip
    current_pool_ip=$(current_metallb_ip)
    local current_prefix new_prefix
    current_prefix=$(ip_prefix "$current_pool_ip")
    new_prefix=$(ip_prefix "$(echo "$METALLB_RANGE" | cut -d- -f1)")
    if [[ "$current_prefix" != "$new_prefix" ]]; then
      warn "MetalLB pool subnet changed: ${current_prefix}.x → ${new_prefix}.x"
      update_metallb_pool "$METALLB_RANGE"
      clean_traefik_external_ips
    fi
  fi

  # Resolve token: use the running cluster's token if RKE2 is already up,
  # otherwise generate a fresh one. This ensures re-runs print the correct token.
  local token
  token=$(resolve_token)

  # Only write the RKE2 config when the cluster has not yet been initialised.
  # We check for the existence of the etcd data directory (created on first
  # bootstrap) rather than just "is the server currently running", so that a
  # re-run after a manual service stop doesn't regenerate the token and break
  # the bootstrap-data decryption on the next start.
  local etcd_data_dir="${RKE2_DATA_DIR}/server/db"
  autojoin_mode="$(resolve_init_advertisement_mode "${init_context}")"

  if systemctl is-active --quiet rke2-server 2>/dev/null || [[ -d "$etcd_data_dir" ]]; then
    log "RKE2 cluster data exists — preserving token, updating tls-san"
    # Always rewrite the tls-san block with the current IP so that a node IP
    # change (DHCP re-assignment, interface rename, etc.) doesn't leave stale
    # addresses in the config and break TLS / etcd peer resolution on the next
    # restart.  The token is preserved from the running cluster.
    local config_file="${RKE2_CONFIG_DIR}/config.yaml"
    if [[ -f "$config_file" ]]; then
      # Rewrite config preserving token but updating tls-san
      local existing_token
      existing_token=$(grep -E '^token:' "$config_file" | awk '{print $2}' | tr -d '"' | head -1)
      [[ -n "$existing_token" ]] && token="$existing_token"
    fi
    mkdir -p "$RKE2_CONFIG_DIR"
    local _short_hn _fqdn
    _short_hn=$(hostname -s 2>/dev/null || hostname)
    _fqdn=$(hostname -f 2>/dev/null || hostname)
    cat > "${RKE2_CONFIG_DIR}/config.yaml" <<EOF
# RKE2 init node — generated by rubik-kubernetes installer
token: "${token}"
write-kubeconfig-mode: "0640"
disable:
  - rke2-servicelb
  - rke2-traefik
tls-san:
  - "${node_ip}"
  - "${_short_hn}"
  - "${_short_hn}.local"
  - "${_fqdn}"
EOF

    # Detect if the node's IP has changed since the cluster was first
    # bootstrapped.  When the IP changes the etcd peer URL stored in the etcd
    # database goes stale, causing rke2-server to fail to start (it prints
    # "this server is not a member of the etcd cluster").  Running
    # `rke2 server --cluster-reset` forces etcd to adopt the current node as
    # its sole member, fixing the peer URL without losing cluster data.
    fix_ip_change "$node_ip"
  else
    step "Writing RKE2 server config (init node)"
    mkdir -p "$RKE2_CONFIG_DIR"
    local _short_hn _fqdn
    _short_hn=$(hostname -s 2>/dev/null || hostname)
    _fqdn=$(hostname -f 2>/dev/null || hostname)
    cat > "${RKE2_CONFIG_DIR}/config.yaml" <<EOF
# RKE2 init node — generated by rubik-kubernetes installer
token: "${token}"
write-kubeconfig-mode: "0640"
disable:
  - rke2-servicelb
  - rke2-traefik
tls-san:
  - "${node_ip}"
  - "${_short_hn}"
  - "${_short_hn}.local"
  - "${_fqdn}"
EOF
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
  install_cpu_topology_labeler
  apply_session_rbac
  patch_coredns_for_session_taint
  label_node_cpu_topology
  install_network_reconcile
  install_cluster_discovery "${autojoin_mode}" "${token}"

  # Record the current IP as the baseline so the reconcile service knows the
  # cluster was fresh-installed with this IP and skips the reset on first boot.
  echo "$node_ip" > "${RKE2_CONFIG_DIR}/last-node-ip"

  print_init_summary "$node_ip" "$token"
}

# ── Join mode ──────────────────────────────────────────────────────────────────
install_join() {
  CLUSTER_ROLE="$(resolve_join_role)"
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
    local _short_hn _fqdn
    _short_hn=$(hostname -s 2>/dev/null || hostname)
    _fqdn=$(hostname -f 2>/dev/null || hostname)
    cat > "${RKE2_CONFIG_DIR}/config.yaml" <<EOF
# RKE2 join node — generated by rubik-kubernetes installer
server: "${CLUSTER_SERVER}"
token: "${CLUSTER_TOKEN}"
write-kubeconfig-mode: "0640"
tls-san:
  - "${node_ip}"
  - "${_short_hn}"
  - "${_short_hn}.local"
  - "${_fqdn}"
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
    if [[ "$rke2_type" == "server" ]]; then
      wait_status "$i" 60 "Still waiting for local RKE2 server health endpoint"
    else
      wait_status "$i" 60 "Still waiting for local RKE2 agent health endpoint"
    fi
    sleep 5
  done

  # Server nodes (additional control-plane members) carry the same
  # node-role.kubernetes.io/control-plane:NoSchedule taint as the init node.
  # Remove it so that session pods and workloads can schedule here too.
  # Agent nodes never have this taint — skip the step for them.
  if [[ "$rke2_type" == "server" ]]; then
    local node_hostname
    node_hostname=$(hostname)
    wait_for_node_ready "$node_hostname"
    remove_control_plane_taints
  fi

  # Label CPU topology on every joining node (init node labels itself separately)
  label_node_cpu_topology
  install_cluster_discovery_runtime
  install_network_reconcile

  # Record the current IP as the baseline for future reconcile runs.
  echo "$node_ip" > "${RKE2_CONFIG_DIR}/last-node-ip"

  print_join_summary
}

resolve_joined_repair_target() {
  local existing_server="$1"
  local existing_token="$2"
  local resolved_server="${existing_server}"
  local resolved_token="${existing_token}"
  local discovered_server=""
  local discovered_token=""
  local discovered_mode=""

  CLUSTER_SERVER="${existing_server}"
  CLUSTER_TOKEN="${existing_token}"
  AUTOJOIN_DISCOVERY_MODE=""

  if try_load_autojoin_from_discovery; then
    discovered_server="${CLUSTER_SERVER}"
    discovered_token="${CLUSTER_TOKEN}"
    discovered_mode="${AUTOJOIN_DISCOVERY_MODE}"

    case "${discovered_mode}" in
      open)
        resolved_server="${discovered_server}"
        resolved_token="${discovered_token}"
        if [[ "${resolved_server}" != "${existing_server}" || "${resolved_token}" != "${existing_token}" ]]; then
          info "Refreshing joined-node endpoint from open LAN discovery: ${resolved_server}"
        fi
        ;;
      manual)
        if [[ "${RETRY_JOIN}" == "1" ]]; then
          err "Retry requested, but the discovered cluster is advertising manual join mode. Re-run with CLUSTER_SERVER=\"${discovered_server}\" and CLUSTER_TOKEN=\"<token>\"."
        fi
        resolved_server="${discovered_server}"
        resolved_token="${existing_token}"
        if [[ "${resolved_server}" != "${existing_server}" ]]; then
          info "Refreshing joined-node endpoint from manual LAN discovery: ${resolved_server}"
        fi
        ;;
    esac
  else
    if [[ "${RETRY_JOIN}" == "1" ]]; then
      case "${LAST_DISCOVERY_STATE:-invalid}" in
        multiple)
          err "Retry requested, but multiple cluster discovery candidates are visible on the LAN. Re-run with explicit CLUSTER_SERVER and CLUSTER_TOKEN."
          ;;
        invalid)
          err "Retry requested, but the discovered cluster advertisement is malformed or incomplete. Fix discovery or re-run with explicit CLUSTER_SERVER and CLUSTER_TOKEN."
          ;;
        runtime-failure)
          err "Retry requested, but cluster discovery browsing failed at runtime. Fix Avahi/discovery or re-run with explicit CLUSTER_SERVER and CLUSTER_TOKEN."
          ;;
        unavailable)
          err "Retry requested, but the cluster discovery helper is unavailable. Re-run with explicit CLUSTER_SERVER and CLUSTER_TOKEN."
          ;;
        none)
          err "Retry requested, but no cluster discovery candidate is currently visible on the LAN. Re-run with explicit CLUSTER_SERVER and CLUSTER_TOKEN."
          ;;
        *)
          err "Retry requested, but no usable discovery target was found."
          ;;
      esac
    fi
    info "Discovery did not yield a usable joined-node repair target — preserving existing endpoint"
  fi

  CLUSTER_SERVER="${resolved_server}"
  CLUSTER_TOKEN="${resolved_token}"
}

repair_joined_node() {
  [[ -n "${CLUSTER_SERVER}" ]] || err "Joined-node repair requires an existing server endpoint."
  [[ -n "${CLUSTER_TOKEN}" ]] || err "Joined-node repair requires an existing token."

  local node_ip
  node_ip=$(detect_node_ip) || err "Cannot detect node IP"

  local rke2_type
  [[ "${CLUSTER_ROLE}" == "agent" ]] && rke2_type="agent" || rke2_type="server"

  step "Refreshing RKE2 ${rke2_type} config for joined-node repair"
  mkdir -p "${RKE2_CONFIG_DIR}"
  local _short_hn _fqdn
  _short_hn=$(hostname -s 2>/dev/null || hostname)
  _fqdn=$(hostname -f 2>/dev/null || hostname)
  cat > "${RKE2_CONFIG_DIR}/config.yaml" <<EOF
# RKE2 join node — generated by rubik-kubernetes installer
server: "${CLUSTER_SERVER}"
token: "${CLUSTER_TOKEN}"
write-kubeconfig-mode: "0640"
tls-san:
  - "${node_ip}"
  - "${_short_hn}"
  - "${_short_hn}.local"
  - "${_fqdn}"
EOF

  install_rke2 "${rke2_type}"
  run_with_progress "Restarting rke2-${rke2_type} to apply refreshed config" "Restarting rke2-${rke2_type}" \
    systemctl restart "rke2-${rke2_type}"
  setup_kubectl
  install_cluster_discovery_runtime
  install_network_reconcile

  local reconcile_cmd="/usr/local/bin/rubik-network-reconcile"
  if [[ ! -x "${reconcile_cmd}" ]]; then
    reconcile_cmd="${SCRIPT_DIR}/scripts/network-reconcile.sh"
  fi

  [[ -x "${reconcile_cmd}" ]] || err "Joined-node repair could not find a runnable network-reconcile script."

  step "Running joined-node repair reconcile"
  "${reconcile_cmd}"

  print_join_summary
}

install_repair() {
  local existing_server existing_token
  existing_server="$(read_rke2_config_value server || true)"

  if [[ -n "${existing_server}" ]]; then
    existing_token="$(read_rke2_config_value token || true)"
    [[ -n "${existing_token}" ]] || err "Existing join config is missing token: ${RKE2_CONFIG_DIR}/config.yaml"
    CLUSTER_ROLE="$(detect_local_join_role)"
    resolve_joined_repair_target "${existing_server}" "${existing_token}"
    repair_joined_node
  else
    install_init "repair"
  fi
}

install_auto_join() {
  local discovery_mode="$1"
  local discovered_mode=""

  load_autojoin_from_discovery
  discovered_mode="${AUTOJOIN_DISCOVERY_MODE:-}"

  case "${discovery_mode}" in
    open)
      [[ "${discovered_mode}" == "open" ]] || \
        err "Expected open discovery mode but found ${discovered_mode}."
      info "Auto-join candidate detected via discovery at ${CLUSTER_SERVER}."
      info "Using discovered join token from LAN advertisement."
      install_join
      ;;
    manual)
      [[ "${discovered_mode}" == "manual" ]] || \
        err "Expected manual discovery mode but found ${discovered_mode}."
      warn "Discovered an existing cluster at ${CLUSTER_SERVER}, but it is advertising manual join mode and withholds the join token."
      err "Manual join credentials are required. Re-run with CLUSTER_SERVER=\"${CLUSTER_SERVER}\" and CLUSTER_TOKEN=\"<token>\"."
      ;;
    *)
      err "Unsupported auto-join discovery mode: ${discovery_mode}"
      ;;
  esac
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
  local install_mode

  parse_cli_args "$@"
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

  install_mode="$(select_install_mode)"

  case "${install_mode}" in
    manual-join)
      echo -e "  ${BOLD}Mode: MANUAL-JOIN${NC} — joining existing cluster at ${CLUSTER_SERVER}"
      install_join
      ;;
    repair)
      if [[ "${RETRY_JOIN}" == "1" ]]; then
        echo -e "  ${BOLD}Mode: REPAIR+RETRY${NC} — rediscovering and reconciling existing local RKE2 install"
      else
        echo -e "  ${BOLD}Mode: REPAIR${NC} — reconciling existing local RKE2 install"
      fi
      install_repair
      ;;
    auto-join-open)
      echo -e "  ${BOLD}Mode: AUTO-JOIN${NC} — joining the discovered cluster via open LAN metadata"
      install_auto_join "open"
      ;;
    auto-join-manual)
      echo -e "  ${BOLD}Mode: DISCOVERED-MANUAL${NC} — cluster found, but manual join credentials are still required"
      install_auto_join "manual"
      ;;
    init)
      echo -e "  ${BOLD}Mode: INIT${NC} — bootstrapping a new cluster"
      install_init "bootstrap"
      ;;
    *)
      err "Unsupported install mode: ${install_mode}"
      ;;
  esac
}

main "$@"
