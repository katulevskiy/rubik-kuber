#!/usr/bin/env bash
# network-reconcile.sh — Detect node IP changes and reconcile Kubernetes accordingly.
#
# Triggered by the rubik-network-reconcile.service systemd unit on every boot
# (after network-online.target) and can also be run manually at any time.
#
# What it does when the node IP has changed:
#   1. Updates /etc/rancher/rke2/config.yaml (tls-san)
#   2. Runs `rke2 server --cluster-reset` to fix the etcd peer URL
#   3. Starts / restarts rke2-server
#   4. Waits for the API server to become ready
#   5. Updates the MetalLB IPAddressPool to match the new subnet
#   6. Waits for Traefik to obtain a new LoadBalancer IP
#   7. Updates the Rancher Helm release with the new nip.io hostname
#   8. Refreshes ~/.kube/config for the ubuntu user

set -euo pipefail

RKE2_CONFIG_DIR="/etc/rancher/rke2"
RKE2_DATA_DIR="/var/lib/rancher/rke2"
KUBECONFIG="${RKE2_CONFIG_DIR}/rke2.yaml"
KUBECTL="${RKE2_DATA_DIR}/bin/kubectl"
STATE_FILE="${RKE2_CONFIG_DIR}/last-node-ip"
HOSTNAME_FILE="${RKE2_CONFIG_DIR}/rancher-hostname"
AUTOJOIN_MODE_FILE="${RKE2_CONFIG_DIR}/autojoin-mode"
CLUSTER_DISCOVERY_BIN="/usr/local/bin/rubik-cluster-discovery"
CLUSTER_DISCOVERY_ENV_FILE="/etc/default/rubik-cluster-advertise"
CLUSTER_DISCOVERY_AVAHI_SERVICE_PATH="/etc/avahi/services/rubik-cluster.service"
LOG_TAG="rubik-net-reconcile"
JOIN_RECONNECT_STATE="unchanged"

log()  { echo "[$(date -u +%H:%M:%S)] $*" | tee /dev/fd/2 | logger -t "$LOG_TAG" 2>/dev/null || true; echo "[$(date -u +%H:%M:%S)] $*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
err()  { log "ERROR $*"; exit 1; }

export KUBECONFIG

if [[ -f "${CLUSTER_DISCOVERY_BIN}" ]]; then
  # shellcheck source=/dev/null
  . "${CLUSTER_DISCOVERY_BIN}"
fi

# ── Detect current node IP ────────────────────────────────────────────────────
detect_node_ip() {
  ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1
}

# ── Read the IP that was active during the last successful reconcile ──────────
last_node_ip() {
  [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo ""
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

read_current_token() {
  local config_file="${RKE2_CONFIG_DIR}/config.yaml"
  local token=""
  local token_file="${RKE2_DATA_DIR}/server/token"

  if [[ -f "${token_file}" ]]; then
    local full
    full=$(cat "${token_file}")
    token="${full##*:}"
  elif [[ -f "${config_file}" ]]; then
    token=$(grep -E '^token:' "${config_file}" | awk '{print $2}' | tr -d '"' | head -1)
  fi

  [[ -n "${token}" ]] || return 1
  printf '%s\n' "${token}"
}

current_short_hostname() {
  hostname -s 2>/dev/null || hostname 2>/dev/null || echo "localhost"
}

current_fqdn() {
  hostname -f 2>/dev/null || hostname 2>/dev/null || echo "localhost"
}

# ── Read the IP stored in etcd's membership database ─────────────────────────
etcd_peer_ip() {
  local etcd_dir="${RKE2_DATA_DIR}/server/db/etcd/member"
  local snap_db="${etcd_dir}/snap/db"
  local ip=""

  if [[ -f "$snap_db" ]]; then
    ip=$(strings "$snap_db" 2>/dev/null \
      | grep -oP 'https?://\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(?=:2380)' \
      | grep -v '^127\.' | head -1 || true)
  fi

  if [[ -z "$ip" ]]; then
    ip=$(strings "${etcd_dir}/wal/"*.wal 2>/dev/null \
      | grep -oP 'https?://\K[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+(?=:2380)' \
      | grep -v '^127\.' | head -1 || true)
  fi

  echo "$ip"
}

# ── Rewrite RKE2 config.yaml with updated tls-san ────────────────────────────
update_rke2_config() {
  local node_ip="$1"
  local config_file="${RKE2_CONFIG_DIR}/config.yaml"
  local token=""
  local short_hostname=""
  local fqdn=""

  token=$(read_current_token || true)
  [[ -n "$token" ]] || { warn "Could not read cluster token — skipping config update"; return 1; }

  mkdir -p "$RKE2_CONFIG_DIR"
  short_hostname=$(current_short_hostname)
  fqdn=$(current_fqdn)

  cat > "$config_file" <<EOF
# RKE2 init node — managed by rubik-kubernetes installer
token: "${token}"
write-kubeconfig-mode: "0640"
disable:
  - rke2-servicelb
  - rke2-traefik
tls-san:
  - "${node_ip}"
  - "${short_hostname}"
  - "${short_hostname}.local"
  - "${fqdn}"
EOF
  info "Updated config.yaml: tls-san → ${node_ip}"
}

# ── Reset etcd cluster membership to fix the peer URL ────────────────────────
run_cluster_reset() {
  local reset_log
  reset_log=$(mktemp /tmp/rke2-cluster-reset.XXXXXX.log)

  info "Starting cluster-reset (updates etcd peer URL)..."
  timeout 120 rke2 server --cluster-reset >"$reset_log" 2>&1 &
  local pid=$!

  local i
  for i in $(seq 1 24); do
    sleep 5
    if grep -q "rke2 is up and running" "$reset_log" 2>/dev/null; then
      kill "$pid" 2>/dev/null || true
      break
    fi
    if ! kill -0 "$pid" 2>/dev/null; then
      break
    fi
  done
  wait "$pid" 2>/dev/null || true
  rm -f "$reset_log"
  info "Cluster-reset complete"
}

# ── Wait for the Kubernetes API to respond ────────────────────────────────────
wait_for_api() {
  local max="${1:-60}"
  info "Waiting for API server to become ready..."
  local i
  for i in $(seq 1 "$max"); do
    if "$KUBECTL" get nodes --request-timeout=5s &>/dev/null; then
      info "API server is ready"
      return 0
    fi
    sleep 5
  done
  err "API server did not become ready after $((max * 5))s"
}

# ── Update MetalLB pool to match the current subnet ──────────────────────────
# MetalLB L2 mode relies on ARP broadcasts which are often filtered by WiFi APs.
# We keep the pool updated so the cluster's LoadBalancer address remains on the
# active subnet and Rancher can continue using the MetalLB-assigned endpoint.
update_metallb() {
  local node_ip="$1"
  local prefix
  prefix=$(echo "$node_ip" | cut -d. -f1-3)
  local new_range="${prefix}.200-${prefix}.220"

  local current_range
  current_range=$("$KUBECTL" get IPAddressPool rubikpi-pool -n metallb-system \
    -o jsonpath='{.spec.addresses[0]}' 2>/dev/null || echo "")

  if [[ "$current_range" == "$new_range" ]]; then
    info "MetalLB pool already correct (${new_range})"
    return 0
  fi

  info "Updating MetalLB pool: ${current_range:-<none>} → ${new_range}"
  "$KUBECTL" apply -f - <<EOF
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: rubikpi-pool
  namespace: metallb-system
spec:
  addresses:
    - "${new_range}"
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
  info "MetalLB pool updated to ${new_range}"
}

# ── Wait for Traefik to obtain its MetalLB LoadBalancer IP ───────────────────
wait_for_traefik_lb_ip() {
  local max="${1:-60}"
  info "Waiting for Traefik to obtain a MetalLB LoadBalancer IP..."
  local i
  for i in $(seq 1 "$max"); do
    local ip
    ip=$("$KUBECTL" get svc traefik -n traefik \
      -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [[ -n "$ip" && "$ip" != "<none>" ]]; then
      info "Traefik LoadBalancer IP: ${ip}"
      echo "$ip"
      return 0
    fi
    sleep 5
  done
  warn "Traefik did not get a LoadBalancer IP after $((max * 5))s"
  echo ""
}

# ── Clear any stale externalIPs from the Traefik service ─────────────────────
# externalIPs were set in a previous design to work around MetalLB WiFi ARP
# issues, but they cause ghost IPs to accumulate.  MetalLB L2 mode is the
# canonical path; externalIPs should stay empty.
clean_traefik_external_ips() {
  local current_ext
  current_ext=$("$KUBECTL" get svc traefik -n traefik \
    -o jsonpath='{.spec.externalIPs[*]}' 2>/dev/null || echo "")
  if [[ -n "$current_ext" ]]; then
    info "Removing stale externalIPs from Traefik: ${current_ext}"
    "$KUBECTL" get svc traefik -n traefik -o json | \
      python3 -c "
import json,sys
svc=json.load(sys.stdin)
svc['spec']['externalIPs']=[]
svc['spec'].pop('loadBalancerIP',None)
print(json.dumps(svc))
" | "$KUBECTL" apply -f - &>/dev/null || true
    info "Traefik externalIPs cleared"
  fi
}

# ── Update Rancher hostname via helm upgrade ──────────────────────────────────
update_rancher() {
  local traefik_ip="$1"
  local new_hostname="rancher.${traefik_ip}.nip.io"
  local new_url="https://${new_hostname}"

  local old_hostname=""
  [[ -f "$HOSTNAME_FILE" ]] && old_hostname=$(cat "$HOSTNAME_FILE")

  if [[ "$old_hostname" == "$new_hostname" ]]; then
    info "Rancher hostname already correct (${new_hostname})"
    # Still ensure the server-url setting matches (it may have been reset)
    patch_rancher_server_url "$new_url"
    return 0
  fi

  info "Updating Rancher hostname: ${old_hostname:-<none>} → ${new_hostname}"
  if helm upgrade rancher rancher-stable/rancher \
    --namespace cattle-system \
    --reuse-values \
    --set "hostname=${new_hostname}" \
    --wait \
    --timeout 5m &>/dev/null; then
    echo "$new_hostname" > "$HOSTNAME_FILE"
    info "Rancher Helm release updated → https://${new_hostname}"
  else
    warn "Rancher helm upgrade failed — will retry on next reconcile"
    return 1
  fi

  # Update Rancher's internal server-url setting.  This is separate from the
  # Helm values: it's a management.cattle.io/v3 Setting resource that Rancher
  # uses for redirects and API callbacks.  If it's stale the browser gets
  # redirected to the old (unreachable) hostname even when accessing the new URL.
  patch_rancher_server_url "$new_url"

  # Restart Rancher so it reads the new server-url cleanly
  "$KUBECTL" rollout restart deployment/rancher -n cattle-system &>/dev/null || true
  "$KUBECTL" rollout status deployment/rancher -n cattle-system --timeout=120s &>/dev/null || true
  info "Rancher restarted with new hostname"
}

patch_rancher_server_url() {
  local new_url="$1"
  local current
  current=$("$KUBECTL" get settings.management.cattle.io server-url \
    -o jsonpath='{.value}' 2>/dev/null || echo "")

  if [[ "$current" == "$new_url" ]]; then
    info "Rancher server-url already correct"
    return 0
  fi

  info "Patching Rancher server-url: ${current:-<none>} → ${new_url}"
  "$KUBECTL" patch settings.management.cattle.io server-url \
    --type merge -p "{\"value\":\"${new_url}\"}" &>/dev/null || \
    warn "Could not patch server-url — Rancher may redirect to old hostname"
}

# ── Refresh ubuntu user's kubeconfig ─────────────────────────────────────────
refresh_kubeconfig() {
  local home_dir
  home_dir=$(getent passwd ubuntu 2>/dev/null | cut -d: -f6 || echo "/home/ubuntu")
  if [[ -f "$KUBECONFIG" && -d "$home_dir" ]]; then
    mkdir -p "${home_dir}/.kube"
    install -m 600 -o ubuntu -g ubuntu "$KUBECONFIG" "${home_dir}/.kube/config" 2>/dev/null || true
    info "Refreshed ~/.kube/config"
  fi
}

# ── Detect node role (server = control-plane, agent = worker) ────────────────
detect_role() {
  if [[ -f "${RKE2_CONFIG_DIR}/config.yaml" ]] && \
     grep -q "^server:" "${RKE2_CONFIG_DIR}/config.yaml" 2>/dev/null; then
    if systemctl is-enabled --quiet rke2-agent.service 2>/dev/null || \
       systemctl is-active --quiet rke2-agent.service 2>/dev/null; then
      echo "agent"
    elif systemctl cat rke2-server.service &>/dev/null || \
         systemctl is-enabled --quiet rke2-server.service 2>/dev/null || \
         systemctl is-active --quiet rke2-server.service 2>/dev/null; then
      echo "joined-server"
    else
      echo "agent"
    fi
  elif systemctl cat rke2-server.service &>/dev/null; then
    echo "server"
  else
    echo "agent"
  fi
}

join_service_name() {
  if systemctl is-enabled --quiet rke2-agent.service 2>/dev/null || \
     systemctl is-active --quiet rke2-agent.service 2>/dev/null; then
    echo "rke2-agent"
  else
    echo "rke2-server"
  fi
}

read_join_config_value() {
  local config_file="${RKE2_CONFIG_DIR}/config.yaml"
  local key="$1"

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

write_join_config_value() {
  local key="$1"
  local value="$2"
  local config_file="${RKE2_CONFIG_DIR}/config.yaml"

  [[ -f "${config_file}" ]] || return 1

  python3 - "$config_file" "$key" "$value" <<'PY'
from pathlib import Path
import sys

config_path = Path(sys.argv[1])
key = sys.argv[2]
value = sys.argv[3]
lines = config_path.read_text().splitlines()
output = []
updated = False

for line in lines:
    if line.startswith(f"{key}:"):
        output.append(f'{key}: "{value}"')
        updated = True
    else:
        output.append(line)

if not updated:
    output.append(f'{key}: "{value}"')

config_path.write_text("\n".join(output) + "\n")
PY
}

update_join_server() {
  local new_server="$1"
  local current_server=""

  current_server=$(read_join_config_value server || true)
  if [[ "${current_server}" == "${new_server}" ]]; then
    info "Join-node config server already correct (${new_server})"
    return 1
  fi

  info "Updating join-node config server: ${current_server:-<none>} → ${new_server}"
  write_join_config_value server "${new_server}"
  return 0
}

update_join_token() {
  local new_token="$1"
  local current_token=""

  [[ -n "${new_token}" ]] || return 1

  current_token=$(read_join_config_value token || true)
  if [[ "${current_token}" == "${new_token}" ]]; then
    info "Join-node config token already current"
    return 1
  fi

  info "Refreshing join-node token from LAN advertisement"
  write_join_config_value token "${new_token}"
  return 0
}

update_join_server_local_config() {
  local node_ip="$1"
  local config_file="${RKE2_CONFIG_DIR}/config.yaml"
  local current_server=""
  local current_token=""
  local short_hostname=""
  local fqdn=""
  local rendered_config=""
  local existing_config=""

  [[ -f "${config_file}" ]] || return 1

  current_server=$(read_join_config_value server || true)
  current_token=$(read_join_config_value token || true)
  [[ -n "${current_server}" && -n "${current_token}" ]] || return 1

  short_hostname=$(current_short_hostname)
  fqdn=$(current_fqdn)
  existing_config="$(<"${config_file}")"
  rendered_config="$(cat <<EOF
# RKE2 join node — managed by rubik-network-reconcile
server: "${current_server}"
token: "${current_token}"
write-kubeconfig-mode: "0640"
tls-san:
  - "${node_ip}"
  - "${short_hostname}"
  - "${short_hostname}.local"
  - "${fqdn}"
EOF
)"

  if [[ "${existing_config}" == "${rendered_config}" ]]; then
    info "Joined server config already matches current IP and hostname state"
    return 1
  fi

  printf '%s\n' "${rendered_config}" > "${config_file}"
  info "Refreshed joined server config for ${node_ip}"
  return 0
}

# Check if a TCP connection to host:port succeeds within 3 seconds
tcp_reachable() {
  local host="$1" port="$2"
  timeout 3 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null
}

extract_server_host() {
  local server_url="$1"
  printf '%s\n' "${server_url}" | sed -E 's#^https?://([^:/]+).*#\1#'
}

extract_server_port() {
  local server_url="$1"
  local parsed_port=""

  parsed_port=$(printf '%s\n' "${server_url}" | sed -nE 's#^https?://[^:/]+:([0-9]+).*$#\1#p')
  if [[ -n "${parsed_port}" ]]; then
    printf '%s\n' "${parsed_port}"
  else
    printf '9345\n'
  fi
}

read_discovery_mode() {
  local mode=""

  if [[ -f "${AUTOJOIN_MODE_FILE}" ]]; then
    mode=$(tr -d '[:space:]' < "${AUTOJOIN_MODE_FILE}")
  fi

  if [[ -z "${mode}" && -f "${CLUSTER_DISCOVERY_ENV_FILE}" ]]; then
    mode=$(read_key_value_file_value "${CLUSTER_DISCOVERY_ENV_FILE}" "DISCOVERY_ADVERTISE_MODE" || true)
  fi

  case "${mode}" in
    open|manual)
      printf '%s\n' "${mode}"
      ;;
    *)
      return 1
      ;;
  esac
}

refresh_cluster_advertisement() {
  local current_ip="$1"
  local advertise_mode=""
  local advertise_token=""
  local short_hostname=""

  if [[ ! -x "${CLUSTER_DISCOVERY_BIN}" ]]; then
    info "Cluster discovery helper not installed — skipping advertisement refresh"
    return 0
  fi

  advertise_mode=$(read_discovery_mode || true)
  if [[ -z "${advertise_mode}" ]]; then
    info "Cluster discovery mode unavailable — skipping advertisement refresh"
    return 0
  fi

  short_hostname=$(current_short_hostname)
  if [[ "${advertise_mode}" == "open" ]]; then
    advertise_token=$(read_current_token || true)
    [[ -n "${advertise_token}" ]] || {
      warn "Cluster discovery mode is open but no token is available — skipping advertisement refresh"
      return 1
    }
  fi

  mkdir -p "$(dirname "${CLUSTER_DISCOVERY_ENV_FILE}")"
  cat > "${CLUSTER_DISCOVERY_ENV_FILE}" <<EOF
# Managed by rubik-network-reconcile.
DISCOVERY_ADVERTISE_MODE=${advertise_mode}
DISCOVERY_ADVERTISE_TOKEN=${advertise_token}
DISCOVERY_ADVERTISE_HOSTNAME=${short_hostname}
DISCOVERY_AVAHI_SERVICE_PATH=${CLUSTER_DISCOVERY_AVAHI_SERVICE_PATH}
EOF

  if DISCOVERY_ADVERTISE_MODE="${advertise_mode}" \
     DISCOVERY_ADVERTISE_TOKEN="${advertise_token}" \
     DISCOVERY_ADVERTISE_HOSTNAME="${short_hostname}" \
     DISCOVERY_AVAHI_SERVICE_PATH="${CLUSTER_DISCOVERY_AVAHI_SERVICE_PATH}" \
     "${CLUSTER_DISCOVERY_BIN}" advertise-service >/dev/null; then
    systemctl restart rubik-cluster-advertise 2>/dev/null || true
    systemctl reload-or-restart avahi-daemon 2>/dev/null || true
    info "Refreshed cluster advertisement (${advertise_mode}, ${short_hostname}.local → ${current_ip})"
  else
    warn "Could not refresh cluster advertisement"
    return 1
  fi
}

load_discovery_target() {
  local record=""
  local server_host=""
  local server_address=""
  local server_port=""
  local mode=""
  local token=""

  declare -F discover_single_cluster >/dev/null 2>&1 || return 1
  declare -F extract_discovery_record_field >/dev/null 2>&1 || return 1

  format_endpoint_url() {
    local host="$1"
    local port="$2"

    if [[ "${host}" == *:* && "${host}" != \[*\] ]]; then
      printf 'https://[%s]:%s\n' "${host}" "${port}"
    else
      printf 'https://%s:%s\n' "${host}" "${port}"
    fi
  }

  record=$(discover_single_cluster 2>/dev/null) || return 1
  [[ -n "${record}" ]] || return 1

  server_host=$(extract_discovery_record_field "${record}" "server_host" || true)
  server_port=$(extract_discovery_record_field "${record}" "server_port" || true)
  server_address=$(printf '%s\n' "${record}" | awk -F';' '
    $1 == "=" {
      if ($8 == "IPv4" || $8 == "IPv6") {
        print $9
      } else {
        print $8
      }
      exit
    }
  ')
  mode=$(extract_discovery_record_field "${record}" "mode" || true)
  token=$(extract_discovery_record_field "${record}" "token" || true)

  [[ -n "${server_host}" && -n "${server_port}" ]] || return 1

  case "${mode}" in
    open)
      [[ -n "${token}" ]] || return 1
      ;;
    manual)
      token=""
      ;;
    *)
      return 1
      ;;
  esac

  printf '%s\n' "${mode}"
  if [[ -n "${server_address}" ]]; then
    format_endpoint_url "${server_address}" "${server_port}"
  else
    format_endpoint_url "${server_host}" "${server_port}"
  fi
  printf '%s\n' "${token}"
}

reconnect_join_node() {
  local config_file="${RKE2_CONFIG_DIR}/config.yaml"
  local current_server=""
  local current_host=""
  local current_port=""
  local discovery_info=()
  local discovery_mode=""
  local discovered_server=""
  local discovered_token=""
  local discovered_host=""
  local discovered_port=""
  local config_changed=false
  local recovered=false

  JOIN_RECONNECT_STATE="unchanged"

  [[ -f "${config_file}" ]] || return 0

  current_server=$(read_join_config_value server || true)
  current_host=$(extract_server_host "${current_server}")
  current_port=$(extract_server_port "${current_server}")

  if [[ -n "${current_host}" ]] && tcp_reachable "${current_host}" "${current_port}"; then
    info "Server ${current_host}:${current_port} is reachable — no rediscovery needed"
    return 0
  fi

  warn "Server ${current_host:-<unknown>}:${current_port} is unreachable — rediscovering by Avahi"

  mapfile -t discovery_info < <(load_discovery_target)
  discovery_mode="${discovery_info[0]:-}"
  discovered_server="${discovery_info[1]:-}"
  discovered_token="${discovery_info[2]:-}"

  if [[ -z "${discovery_mode}" || -z "${discovered_server}" ]]; then
    warn "No unique cluster discovery record is available — leaving join config unchanged"
    return 0
  fi

  discovered_host=$(extract_server_host "${discovered_server}")
  discovered_port=$(extract_server_port "${discovered_server}")
  if ! tcp_reachable "${discovered_host}" "${discovered_port}"; then
    warn "Discovered server ${discovered_host}:${discovered_port} is still unreachable — leaving join config unchanged"
    return 0
  fi
  recovered=true

  if update_join_server "${discovered_server}"; then
    config_changed=true
  fi

  if [[ "${discovery_mode}" == "open" ]] && update_join_token "${discovered_token}"; then
    config_changed=true
  fi

  if [[ "${config_changed}" == true ]]; then
    JOIN_RECONNECT_STATE="changed"
  elif [[ "${recovered}" == true ]]; then
    JOIN_RECONNECT_STATE="recovered"
  fi
}

# ── Join-node reconciliation (agent or secondary server) ─────────────────────
main_join_node() {
  local current_ip="$1"
  local prev_ip="$2"
  local join_service=""

  join_service=$(join_service_name)
  reconnect_join_node

  # Agent nodes connect outward to the control-plane — their own IP only
  # matters for kubelet registration.  RKE2 agent re-registers automatically
  # or server certs need a restart when the node address or join target changes.
  if [[ "${JOIN_RECONNECT_STATE}" == "changed" ]]; then
    info "Join target changed — restarting ${join_service}"
    systemctl restart "${join_service}" 2>/dev/null || true
  elif [[ "${JOIN_RECONNECT_STATE}" == "recovered" ]]; then
    info "Join target was rediscovered successfully — restarting ${join_service}"
    systemctl restart "${join_service}" 2>/dev/null || true
  elif [[ "$current_ip" != "$prev_ip" ]]; then
    info "Join-node IP changed (${prev_ip:-first run} → ${current_ip}) — restarting ${join_service}"
    systemctl restart "${join_service}" 2>/dev/null || true
  elif ! systemctl is-active --quiet "${join_service}"; then
    info "${join_service} not running — starting"
    systemctl start "${join_service}" 2>/dev/null || true
  else
    info "Join node healthy, no action needed"
  fi

  echo "$current_ip" > "$STATE_FILE"
  info "Join-node reconciliation complete. Node IP: ${current_ip}"
}

main_joined_server() {
  local current_ip="$1"
  local prev_ip="$2"
  local config_changed=false
  local need_restart=false

  reconnect_join_node

  if update_join_server_local_config "${current_ip}"; then
    config_changed=true
  fi

  if [[ "${JOIN_RECONNECT_STATE}" == "changed" ]]; then
    info "Join target changed — restarting rke2-server"
    need_restart=true
  elif [[ "${JOIN_RECONNECT_STATE}" == "recovered" ]]; then
    info "Join target was rediscovered successfully — restarting rke2-server"
    need_restart=true
  elif [[ "${config_changed}" == true ]]; then
    info "Joined server config changed — restarting rke2-server"
    need_restart=true
  elif [[ "$current_ip" != "$prev_ip" ]]; then
    info "Joined server IP changed (${prev_ip:-first run} → ${current_ip}) — restarting rke2-server"
    need_restart=true
  elif ! systemctl is-active --quiet rke2-server; then
    info "rke2-server not running — starting"
    systemctl start rke2-server 2>/dev/null || true
    need_restart=false
    wait_for_api 72
    refresh_kubeconfig
    echo "$current_ip" > "$STATE_FILE"
    info "Joined-server reconciliation complete. Node IP: ${current_ip}"
    return 0
  else
    info "Joined server healthy, no action needed"
  fi

  if [[ "${need_restart}" == true ]]; then
    systemctl restart rke2-server 2>/dev/null || true
    wait_for_api 72
    refresh_kubeconfig
  fi

  echo "$current_ip" > "$STATE_FILE"
  info "Joined-server reconciliation complete. Node IP: ${current_ip}"
}

# ── Server reconciliation (full: etcd reset, MetalLB, Traefik, Rancher) ──────
main_server() {
  local current_ip="$1"
  local prev_ip="$2"

  local stored_etcd_ip
  stored_etcd_ip=$(etcd_peer_ip)

  info "etcd peer IP    : ${stored_etcd_ip:-<unknown>}"

  local need_rke2_restart=false
  local need_cluster_reset=false

  if [[ "$current_ip" != "$prev_ip" ]]; then
    info "Node IP has changed (${prev_ip:-first run} → ${current_ip}) — reconciling"
    need_rke2_restart=true
    if [[ -n "$stored_etcd_ip" && "$stored_etcd_ip" != "$current_ip" ]]; then
      need_cluster_reset=true
    fi
  else
    info "Node IP unchanged (${current_ip}) — checking service health"
  fi

  update_rke2_config "$current_ip"
  # Write a hint file so agent nodes can discover the new control-plane IP.
  echo "$current_ip" > "${RKE2_CONFIG_DIR}/server-ip"
  refresh_cluster_advertisement "$current_ip" || true

  if [[ "$need_cluster_reset" == true ]]; then
    systemctl stop rke2-server 2>/dev/null || true
    sleep 2
    run_cluster_reset
  fi

  if [[ "$need_rke2_restart" == true ]] || ! systemctl is-active --quiet rke2-server; then
    info "Starting rke2-server..."
    systemctl restart rke2-server
    sleep 10
  fi

  wait_for_api 72
  refresh_kubeconfig

  # Always clean stale externalIPs (a previous version of this script set them)
  clean_traefik_external_ips

  if [[ "$current_ip" != "$prev_ip" ]]; then
    update_metallb "$current_ip"
  fi

  # Use the MetalLB-assigned LoadBalancer IP (stable .200 address) for Rancher,
  # not the node's DHCP IP which changes.  If we can't get the LB IP, fall back
  # to the node IP so Rancher is at least reachable.
  local traefik_lb_ip
  traefik_lb_ip=$(wait_for_traefik_lb_ip 24)
  local rancher_access_ip="${traefik_lb_ip:-$current_ip}"

  if [[ "$current_ip" != "$prev_ip" ]]; then
    update_rancher "$rancher_access_ip" || true
  else
    patch_rancher_server_url "https://rancher.${rancher_access_ip}.nip.io"
  fi

  echo "$current_ip" > "$STATE_FILE"
  info "Server reconciliation complete. Node IP: ${current_ip}"

  if [[ -f "$HOSTNAME_FILE" ]]; then
    local ui_host
    ui_host=$(cat "$HOSTNAME_FILE")
    echo
    echo "  Rancher UI: https://${ui_host}"
    echo "  Password:   rubikpi-admin"
    echo
  fi
}

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  [[ $EUID -eq 0 ]] || err "Run as root: sudo $0"

  local current_ip
  current_ip=$(detect_node_ip) || err "Cannot detect node IP"

  if declare -F ensure_local_mdns_resolution >/dev/null 2>&1; then
    ensure_local_mdns_resolution || warn "Could not update nsswitch.conf for .local name resolution"
  fi
  if declare -F ensure_avahi_physical_interface_binding >/dev/null 2>&1; then
    ensure_avahi_physical_interface_binding || warn "Could not bind Avahi to the detected physical interface"
  fi

  local prev_ip
  prev_ip=$(last_node_ip)

  local role
  role=$(detect_role)

  info "Node role       : ${role}"
  info "Current node IP : ${current_ip}"
  info "Last seen IP    : ${prev_ip:-<none>}"

  if [[ "$role" == "agent" ]]; then
    main_join_node "$current_ip" "$prev_ip"
  elif [[ "$role" == "joined-server" ]]; then
    main_joined_server "$current_ip" "$prev_ip"
  else
    main_server "$current_ip" "$prev_ip"
  fi
}

main "$@"
