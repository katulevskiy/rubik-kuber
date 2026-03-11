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

test_default_join_role_is_agent() {
  CLUSTER_ROLE=""
  assert_eq "agent" "$(resolve_join_role)" \
    "later-node auto-join should default to agent when CLUSTER_ROLE is unset"
}

test_explicit_server_role_is_preserved() {
  CLUSTER_ROLE="server"
  assert_eq "server" "$(resolve_join_role)" \
    "explicit server join role should still be available"
}

test_explicit_agent_role_is_preserved() {
  CLUSTER_ROLE="agent"
  assert_eq "agent" "$(resolve_join_role)" \
    "explicit agent join role should still be available"
}

test_default_join_role_is_agent
test_explicit_server_role_is_preserved
test_explicit_agent_role_is_preserved

printf 'PASS: install auto-join role checks\n'
