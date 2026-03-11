#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${ROOT_DIR}/install.sh"
SESSION_SH="${ROOT_DIR}/scripts/session.sh"

fail() {
  printf 'FAIL: %s\n' "$*" >&2
  exit 1
}

assert_contains() {
  local needle="$1"
  local haystack="$2"
  local message="$3"
  [[ "${haystack}" == *"${needle}"* ]] || fail "${message}: missing '${needle}'"
}

install_source="$(<"${INSTALL_SH}")"
session_source="$(<"${SESSION_SH}")"

assert_contains "patch_coredns_for_session_taint" "${install_source}" \
  "installer should patch CoreDNS to tolerate the exclusive session taint"

assert_contains "cleanup_orphan_session_taints" "${session_source}" \
  "session manager should proactively clean orphaned exclusive-session taints"

assert_contains "cleanup_orphan_session_taints" "${session_source#*cmd_start()}" \
  "session start flow should invoke orphaned taint cleanup before scheduling a new session"

printf 'PASS: session/CoreDNS regression checks\n'
