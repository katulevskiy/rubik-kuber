#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${ROOT_DIR}/install.sh"
DISCOVERY_SH="${ROOT_DIR}/scripts/cluster-discovery.sh"
RECONCILE_SH="${ROOT_DIR}/scripts/network-reconcile.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_eq() {
  local expected="$1"
  local actual="$2"
  local message="$3"
  [[ "${expected}" == "${actual}" ]] || fail "${message}: expected '${expected}', got '${actual}'"
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  local message="$3"
  [[ "${haystack}" == *"${needle}"* ]] || fail "${message}: missing '${needle}'"
}

source_install_helpers() {
  # shellcheck source=/dev/null
  source <(python3 - "${INSTALL_SH}" <<'PY'
from pathlib import Path
import sys
lines = Path(sys.argv[1]).read_text().splitlines()
for line in lines:
    if line.strip() == 'main "$@"':
        break
    print(line)
PY
)
}

source_reconcile_helpers() {
  # shellcheck source=/dev/null
  source <(python3 - "${RECONCILE_SH}" <<'PY'
from pathlib import Path
import sys
lines = Path(sys.argv[1]).read_text().splitlines()
for line in lines:
    if line.strip() == 'main "$@"':
        break
    print(line)
PY
)
}

test_unique_discovery_rows_are_deduped() {
  # shellcheck source=/dev/null
  source "${DISCOVERY_SH}"

  discover_cluster_records() {
    cat <<'EOF'
=;eth0;IPv4;rubik-cluster;_rubik-k8s._tcp;local;rubikpi.local;IPv4;192.168.1.10;9345;"cluster_name=rubik-cluster";"mode=open";"server_host=rubikpi.local";"server_port=9345";"token=abc";"version=1"
=;wlan0;IPv4;rubik-cluster;_rubik-k8s._tcp;local;rubikpi.local;IPv4;192.168.1.10;9345;"cluster_name=rubik-cluster";"mode=open";"server_host=rubikpi.local";"server_port=9345";"token=abc";"version=1"
=;eth0;IPv6;rubik-cluster;_rubik-k8s._tcp;local;rubikpi.local;IPv6;fe80::1;9345;"cluster_name=rubik-cluster";"mode=open";"server_host=rubikpi.local";"server_port=9345";"token=abc";"version=1"
EOF
  }

  local record
  record="$(discover_single_cluster)"
  assert_contains "server_host=rubikpi.local" "${record}" "deduped discovery should keep the shared service"
}

test_physical_interface_binding_is_rendered() {
  # shellcheck source=/dev/null
  source "${DISCOVERY_SH}"

  local rendered
  rendered="$(render_avahi_daemon_config "eth0")"
  assert_contains "[server]" "${rendered}" "Avahi config should include the server section"
  assert_contains "allow-interfaces=eth0" "${rendered}" "Avahi config should bind to the physical LAN interface"
}

test_local_mdns_support_is_provisioned() {
  local install_source
  install_source="$(<"${INSTALL_SH}")"
  assert_contains "libnss-mdns" "${install_source}" "installer should provision the NSS mDNS package"

  source_install_helpers

  local hosts_line
  hosts_line="$(ensure_mdns_hosts_line "hosts: files dns")"
  assert_contains "mdns4_minimal [NOTFOUND=return]" "${hosts_line}" "nsswitch hosts line should gain mDNS resolution"
}

test_joined_server_role_is_distinct() {
  local temp_root
  temp_root="$(mktemp -d)"
  trap 'rm -rf "${temp_root}"' RETURN

  mkdir -p "${temp_root}/etc/rancher/rke2"
  cat > "${temp_root}/etc/rancher/rke2/config.yaml" <<'EOF'
server: "https://rubikpi.local:9345"
token: "abc"
EOF

  systemctl() {
    if [[ "${1:-}" == "cat" && "${2:-}" == "rke2-server.service" ]]; then
      return 0
    fi
    return 1
  }

  source_reconcile_helpers
  RKE2_CONFIG_DIR="${temp_root}/etc/rancher/rke2"

  local role
  role="$(detect_role)"
  assert_eq "joined-server" "${role}" "joined control-plane nodes should not be treated as agents"
}

test_unique_discovery_rows_are_deduped
test_physical_interface_binding_is_rendered
test_local_mdns_support_is_provisioned
test_joined_server_role_is_distinct

printf 'PASS: final implementation blocker checks\n'
