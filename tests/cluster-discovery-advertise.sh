#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISCOVERY_SH="${ROOT_DIR}/scripts/cluster-discovery.sh"

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

tmpdir="$(mktemp -d)"
trap 'rm -rf "${tmpdir}"' EXIT

# shellcheck source=/dev/null
source "${DISCOVERY_SH}"

service_path="${tmpdir}/rubik-cluster.service"
DISCOVERY_ADVERTISE_MODE="open" \
DISCOVERY_ADVERTISE_TOKEN="secret-token" \
DISCOVERY_ADVERTISE_HOSTNAME="rubikpi" \
DISCOVERY_AVAHI_SERVICE_PATH="${service_path}" \
  advertise_service >/dev/null

[[ -f "${service_path}" ]] || fail "advertise_service should create the Avahi service file"

mode="$(stat -c '%a' "${service_path}")"
[[ "${mode}" == "644" ]] || fail "advertised Avahi service file should be world-readable, got mode ${mode}"

payload="$(<"${service_path}")"
assert_contains "<txt-record>mode=open</txt-record>" "${payload}" \
  "advertised payload should include open mode"
assert_contains "<txt-record>token=secret-token</txt-record>" "${payload}" \
  "advertised payload should include the open-mode token"

printf 'PASS: cluster discovery advertise file checks\n'
