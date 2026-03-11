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
LOG_TAG="rubik-net-reconcile"

log()  { echo "[$(date -u +%H:%M:%S)] $*" | tee /dev/fd/2 | logger -t "$LOG_TAG" 2>/dev/null || true; echo "[$(date -u +%H:%M:%S)] $*"; }
info() { log "INFO  $*"; }
warn() { log "WARN  $*"; }
err()  { log "ERROR $*"; exit 1; }

export KUBECONFIG

# ── Detect current node IP ────────────────────────────────────────────────────
detect_node_ip() {
  ip route get 1.1.1.1 2>/dev/null | grep -oP 'src \K\S+' | head -1
}

# ── Read the IP that was active during the last successful reconcile ──────────
last_node_ip() {
  [[ -f "$STATE_FILE" ]] && cat "$STATE_FILE" || echo ""
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
  # Prefer the live cluster token (most authoritative)
  local token_file="${RKE2_DATA_DIR}/server/token"
  if [[ -f "$token_file" ]]; then
    local full
    full=$(cat "$token_file")
    token="${full##*:}"
  elif [[ -f "$config_file" ]]; then
    token=$(grep -E '^token:' "$config_file" | awk '{print $2}' | tr -d '"' | head -1)
  fi

  [[ -n "$token" ]] || { warn "Could not read cluster token — skipping config update"; return 1; }

  mkdir -p "$RKE2_CONFIG_DIR"
  local short_hostname
  short_hostname=$(hostname -s 2>/dev/null || hostname)
  local fqdn
  fqdn=$(hostname -f 2>/dev/null || hostname)

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
# We keep the pool updated for wired setups, but the primary access path for
# Traefik is the node's own IP set via externalIPs (see update_traefik_external_ip).
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
  if systemctl cat rke2-server.service &>/dev/null && \
     [[ -f "${RKE2_CONFIG_DIR}/config.yaml" ]] && \
     ! grep -q "^server:" "${RKE2_CONFIG_DIR}/config.yaml" 2>/dev/null; then
    echo "server"
  else
    echo "agent"
  fi
}

# ── Try to resolve the control-plane IP from a hint file ─────────────────────
# When the init node IP changes, agent nodes need to know the new server address.
# install.sh writes CLUSTER_SERVER_IP to a hint file at join time.  The
# network-reconcile service on the init node also updates this file when its IP
# changes so agents that share a filesystem (e.g. NFS) get the update; for
# non-shared setups the hint is only set once.
resolve_server_ip() {
  local config_file="${RKE2_CONFIG_DIR}/config.yaml"
  local hint_file="${RKE2_CONFIG_DIR}/server-ip"

  # Prefer the hint file (updated by init node reconcile when possible)
  if [[ -f "$hint_file" ]]; then
    cat "$hint_file"
    return
  fi
  # Fall back to the server: line already in config.yaml
  grep -oP 'server:\s+"?https?://\K[0-9.]+' "$config_file" 2>/dev/null | head -1 || echo ""
}

# Update the server: line in the agent's config.yaml to point to a new IP.
update_agent_server_ip() {
  local new_server_ip="$1"
  local config_file="${RKE2_CONFIG_DIR}/config.yaml"

  [[ -f "$config_file" ]] || return 0

  local current_entry
  current_entry=$(grep -oP 'server:\s+"\K[^"]+' "$config_file" 2>/dev/null | head -1 || echo "")
  local new_entry="https://${new_server_ip}:9345"

  if [[ "$current_entry" == "$new_entry" ]]; then
    info "Agent config server already correct (${new_entry})"
    return 0
  fi

  info "Updating agent config server: ${current_entry:-<none>} → ${new_entry}"
  sed -i "s|^server:.*|server: \"${new_entry}\"|" "$config_file"
  info "Agent config updated"
}

# Check if a TCP connection to host:port succeeds within 3 seconds
tcp_reachable() {
  local host="$1" port="$2"
  timeout 3 bash -c "echo >/dev/tcp/${host}/${port}" 2>/dev/null
}

# Try to find the control-plane IP by testing known hostnames and the hint file.
# Updates the agent config if a reachable server is found at a different address.
autodiscover_server() {
  local config_file="${RKE2_CONFIG_DIR}/config.yaml"
  [[ -f "$config_file" ]] || return 0

  local current_entry
  current_entry=$(grep -oP 'server:\s+"\K[^"]+' "$config_file" 2>/dev/null | head -1 || echo "")
  local current_host
  current_host=$(echo "$current_entry" | grep -oP 'https?://\K[^:/]+' || echo "")

  # If the current server is already reachable, nothing to do
  if [[ -n "$current_host" ]] && tcp_reachable "$current_host" 9345; then
    info "Server ${current_host}:9345 is reachable — no autodiscovery needed"
    return 0
  fi

  warn "Server ${current_host:-<unknown>}:9345 is unreachable — trying autodiscovery"

  # Try candidates in order: hint file, then mDNS hostname
  local candidates=()
  [[ -f "${RKE2_CONFIG_DIR}/server-ip" ]] && candidates+=("$(cat "${RKE2_CONFIG_DIR}/server-ip")")
  # Try resolving the control-plane by its mDNS/hostname (removes the .local suffix for direct)
  for name in rubikpi.local rubikpi; do
    local resolved
    resolved=$(getent ahostsv4 "$name" 2>/dev/null | awk '{print $1; exit}' || true)
    [[ -n "$resolved" ]] && candidates+=("$resolved")
  done

  for candidate in "${candidates[@]}"; do
    [[ -z "$candidate" ]] && continue
    if tcp_reachable "$candidate" 9345; then
      info "Found reachable server at ${candidate}:9345"
      update_agent_server_ip "$candidate"
      return 0
    fi
  done

  warn "Could not autodiscover control-plane — rke2-agent may fail to connect"
}

# ── Agent reconciliation (no etcd, no kubectl, just restart rke2-agent) ──────
main_agent() {
  local current_ip="$1"
  local prev_ip="$2"

  # Auto-discover the control-plane if the configured server is unreachable.
  # This handles the case where the control-plane node changed its DHCP IP.
  autodiscover_server

  # Agent nodes connect outward to the control-plane — their own IP only
  # matters for kubelet registration.  RKE2 agent re-registers automatically
  # on restart, so the only action needed when the IP changes is a service
  # restart so kubelet picks up the new node IP.
  if [[ "$current_ip" != "$prev_ip" ]]; then
    info "Agent IP changed (${prev_ip:-first run} → ${current_ip}) — restarting rke2-agent"
    systemctl restart rke2-agent 2>/dev/null || true
  elif ! systemctl is-active --quiet rke2-agent; then
    info "rke2-agent not running — starting"
    systemctl start rke2-agent 2>/dev/null || true
  else
    info "Agent healthy, no action needed"
  fi

  echo "$current_ip" > "$STATE_FILE"
  info "Agent reconciliation complete. Node IP: ${current_ip}"
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

  local prev_ip
  prev_ip=$(last_node_ip)

  local role
  role=$(detect_role)

  info "Node role       : ${role}"
  info "Current node IP : ${current_ip}"
  info "Last seen IP    : ${prev_ip:-<none>}"

  if [[ "$role" == "agent" ]]; then
    main_agent "$current_ip" "$prev_ip"
  else
    main_server "$current_ip" "$prev_ip"
  fi
}

main "$@"
