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
  cat > "$config_file" <<EOF
# RKE2 init node — managed by rubik-kubernetes installer
token: "${token}"
write-kubeconfig-mode: "0640"
disable:
  - rke2-servicelb
  - rke2-traefik
tls-san:
  - "${node_ip}"
  - "$(hostname -f 2>/dev/null || hostname)"
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

# ── Set the node's own IP as externalIPs on the Traefik service ──────────────
# MetalLB L2/ARP doesn't work reliably on WiFi (APs filter broadcasts between
# clients).  Setting externalIPs to the node's actual IP sidesteps ARP entirely:
# kube-proxy creates iptables DNAT rules so that port 80/443 on the node IP
# goes straight to Traefik pods.  This is the reliable access path on WiFi.
update_traefik_external_ip() {
  local node_ip="$1"

  local current_ext
  current_ext=$("$KUBECTL" get svc traefik -n traefik \
    -o jsonpath='{.spec.externalIPs[0]}' 2>/dev/null || echo "")

  if [[ "$current_ext" == "$node_ip" ]]; then
    info "Traefik externalIPs already correct (${node_ip})"
    return 0
  fi

  info "Patching Traefik externalIPs: ${current_ext:-<none>} → ${node_ip}"
  "$KUBECTL" patch svc traefik -n traefik \
    --type merge -p "{\"spec\":{\"externalIPs\":[\"${node_ip}\"]}}" &>/dev/null
  info "Traefik now reachable at ${node_ip}:80 / ${node_ip}:443"
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

# ── Main ──────────────────────────────────────────────────────────────────────
main() {
  [[ $EUID -eq 0 ]] || err "Run as root: sudo $0"

  local current_ip
  current_ip=$(detect_node_ip) || err "Cannot detect node IP"

  local prev_ip
  prev_ip=$(last_node_ip)

  local stored_etcd_ip
  stored_etcd_ip=$(etcd_peer_ip)

  info "Current node IP : ${current_ip}"
  info "Last seen IP    : ${prev_ip:-<none>}"
  info "etcd peer IP    : ${stored_etcd_ip:-<unknown>}"

  local need_rke2_restart=false
  local need_cluster_reset=false

  # ── Detect what changed ────────────────────────────────────────────────────
  if [[ "$current_ip" != "$prev_ip" ]]; then
    info "Node IP has changed (${prev_ip:-first run} → ${current_ip}) — reconciling"
    need_rke2_restart=true

    # Only reset etcd if the peer URL is stale
    if [[ -n "$stored_etcd_ip" && "$stored_etcd_ip" != "$current_ip" ]]; then
      need_cluster_reset=true
    fi
  else
    info "Node IP unchanged (${current_ip}) — checking service health"
  fi

  # ── Always make sure the config reflects the current IP ───────────────────
  update_rke2_config "$current_ip"

  # ── Cluster reset if etcd peer URL is stale ───────────────────────────────
  if [[ "$need_cluster_reset" == true ]]; then
    systemctl stop rke2-server 2>/dev/null || true
    sleep 2
    run_cluster_reset
  fi

  # ── Start / restart rke2-server if IP changed or it is not running ────────
  if [[ "$need_rke2_restart" == true ]] || ! systemctl is-active --quiet rke2-server; then
    info "Starting rke2-server..."
    systemctl restart rke2-server
    sleep 10
  fi

  # ── Wait for the API server ───────────────────────────────────────────────
  wait_for_api 72  # up to 6 minutes

  # ── Refresh kubeconfig now that the API is up ─────────────────────────────
  refresh_kubeconfig

  # ── Update network-layer resources when IP changed ───────────────────────
  if [[ "$current_ip" != "$prev_ip" ]]; then
    # Keep MetalLB pool in the right subnet (for wired setups).
    update_metallb "$current_ip"

    # Always patch Traefik's externalIPs to the node's own IP so it's
    # reachable from the LAN regardless of whether MetalLB ARP is working.
    # On WiFi, ARP-based VIPs are unreliable; externalIPs on the real node
    # IP always works because the node already owns that IP on the network.
    update_traefik_external_ip "$current_ip"

    # Use the node IP directly for the Rancher hostname (not the MetalLB VIP).
    update_rancher "$current_ip" || true
  else
    # IP unchanged — still ensure externalIPs is set (survives pod restarts)
    update_traefik_external_ip "$current_ip"
    # Ensure server-url is correct even if unchanged
    patch_rancher_server_url "https://rancher.${current_ip}.nip.io"
  fi

  # ── Save current IP as the new baseline ──────────────────────────────────
  echo "$current_ip" > "$STATE_FILE"
  info "Reconciliation complete. Node IP: ${current_ip}"

  # ── Print summary ─────────────────────────────────────────────────────────
  if [[ "$current_ip" != "$prev_ip" && -f "$HOSTNAME_FILE" ]]; then
    echo
    echo "  Rancher UI: https://$(cat "$HOSTNAME_FILE")"
    echo "  Password:   rubikpi-admin"
    echo
  fi
}

main "$@"
