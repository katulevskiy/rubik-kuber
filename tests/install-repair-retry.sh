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

test_parse_cli_args_enables_retry() {
  RETRY_JOIN=0
  parse_cli_args --retry
  assert_eq "1" "${RETRY_JOIN}" \
    "--retry should enable retry mode"
}

test_repair_refreshes_stale_endpoint_from_open_discovery() {
  inspect_discovery_candidate() {
    cat <<'EOF'
open
=;eth0;IPv4;rubik-cluster;_rubik-k8s._tcp;local;rubikpi.local;192.168.0.223;9345;"cluster_name=rubik-cluster";"mode=open";"server_host=rubikpi.local";"server_port=9345";"token=fresh-token";"version=1"
EOF
  }

  parse_discovery_record_field() {
    local record="$1"
    local field_name="$2"
    case "${field_name}" in
      server_host) printf '%s\n' "rubikpi.local" ;;
      server_port) printf '%s\n' "9345" ;;
      token) printf '%s\n' "fresh-token" ;;
      *) return 1 ;;
    esac
  }

  CLUSTER_SERVER=""
  CLUSTER_TOKEN=""
  RETRY_JOIN=0
  resolve_joined_repair_target "https://rubikpi.local:9345" "stale-token"
  assert_eq "https://192.168.0.223:9345" "${CLUSTER_SERVER}" \
    "repair should refresh the join endpoint to the discovered IP"
  assert_eq "fresh-token" "${CLUSTER_TOKEN}" \
    "open discovery should refresh the join token"
}

test_repair_preserves_existing_token_for_manual_discovery() {
  inspect_discovery_candidate() {
    cat <<'EOF'
manual
=;eth0;IPv4;rubik-cluster;_rubik-k8s._tcp;local;rubikpi.local;192.168.0.224;9345;"cluster_name=rubik-cluster";"mode=manual";"server_host=rubikpi.local";"server_port=9345";"version=1"
EOF
  }

  parse_discovery_record_field() {
    local record="$1"
    local field_name="$2"
    case "${field_name}" in
      server_host) printf '%s\n' "rubikpi.local" ;;
      server_port) printf '%s\n' "9345" ;;
      token) return 1 ;;
      *) return 1 ;;
    esac
  }

  CLUSTER_SERVER=""
  CLUSTER_TOKEN=""
  RETRY_JOIN=0
  resolve_joined_repair_target "https://old-hostname.local:9345" "existing-token"
  assert_eq "https://192.168.0.224:9345" "${CLUSTER_SERVER}" \
    "manual discovery should still refresh the join endpoint to the discovered IP"
  assert_eq "existing-token" "${CLUSTER_TOKEN}" \
    "manual discovery should preserve the existing local token"
}

test_repair_keeps_existing_values_when_discovery_absent() {
  inspect_discovery_candidate() {
    cat <<'EOF'
none

EOF
  }

  CLUSTER_SERVER=""
  CLUSTER_TOKEN=""
  RETRY_JOIN=0
  resolve_joined_repair_target "https://persisted.invalid:9345" "persisted-token"
  assert_eq "https://persisted.invalid:9345" "${CLUSTER_SERVER}" \
    "repair should keep the existing server when discovery is absent"
  assert_eq "persisted-token" "${CLUSTER_TOKEN}" \
    "repair should keep the existing token when discovery is absent"
}

test_parse_cli_args_enables_retry
test_repair_refreshes_stale_endpoint_from_open_discovery
test_repair_preserves_existing_token_for_manual_discovery
test_repair_keeps_existing_values_when_discovery_absent

printf 'PASS: install repair retry checks\n'
