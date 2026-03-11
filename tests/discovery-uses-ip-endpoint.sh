#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${ROOT_DIR}/install.sh"

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

source_install_helpers

record='=;eth0;IPv4;rubik-cluster;_rubik-k8s._tcp;local;rubikpi.local;192.168.0.223;9345;"cluster_name=rubik-cluster";"mode=open";"server_host=rubikpi.local";"server_port=9345";"token=test-token";"version=1"'

assert_eq "192.168.0.223" "$(parse_discovery_record_address "${record}")" \
  "discovery parser should read the resolved service IP from the Avahi record"
assert_eq "9345" "$(parse_discovery_record_service_port "${record}")" \
  "discovery parser should read the service port from the Avahi record"

inspect_discovery_candidate() {
  cat <<'EOF'
open
=;eth0;IPv4;rubik-cluster;_rubik-k8s._tcp;local;rubikpi.local;192.168.0.223;9345;"cluster_name=rubik-cluster";"mode=open";"server_host=rubikpi.local";"server_port=9345";"token=test-token";"version=1"
EOF
}

parse_discovery_record_field() {
  local record="$1"
  local field_name="$2"
  case "${field_name}" in
    server_host) printf '%s\n' "rubikpi.local" ;;
    server_port) printf '%s\n' "9345" ;;
    token) printf '%s\n' "test-token" ;;
    *) return 1 ;;
  esac
}

load_autojoin_from_discovery

assert_eq "https://192.168.0.223:9345" "${CLUSTER_SERVER}" \
  "auto-join should use the discovered IP endpoint for the actual join server"
assert_eq "test-token" "${CLUSTER_TOKEN}" \
  "auto-join should still load the discovered token"

printf 'PASS: discovery join endpoint uses IP address\n'
