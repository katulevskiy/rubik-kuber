#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${ROOT_DIR}/install.sh"
MANIFEST="${ROOT_DIR}/manifests/cpu-topology-labeler.yaml"

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

[[ -f "${MANIFEST}" ]] || fail "CPU topology labeler manifest should exist"

install_source="$(<"${INSTALL_SH}")"
manifest_source="$(<"${MANIFEST}")"

assert_contains "install_cpu_topology_labeler" "${install_source}" \
  "installer should define a CPU topology labeler install hook"

assert_contains "install_cpu_topology_labeler" "${install_source#*install_device_plugin}" \
  "server-side install flow should apply the CPU topology labeler"

assert_contains "kind: ServiceAccount" "${manifest_source}" \
  "labeler manifest should create a service account"

assert_contains "kind: ClusterRole" "${manifest_source}" \
  "labeler manifest should create a cluster role"

assert_contains "kind: ClusterRoleBinding" "${manifest_source}" \
  "labeler manifest should bind RBAC for node labeling"

assert_contains "kind: DaemonSet" "${manifest_source}" \
  "labeler manifest should run as a DaemonSet on cluster nodes"

assert_contains "rubikpi.ai/cpu-silver-cores" "${manifest_source}" \
  "labeler manifest should patch the silver core label"

assert_contains "rubikpi.ai/cpu-gold-cores" "${manifest_source}" \
  "labeler manifest should patch the gold core label"

assert_contains "rubikpi.ai/cpu-gold-plus-cores" "${manifest_source}" \
  "labeler manifest should patch the gold-plus core label"

assert_contains "fieldPath: spec.nodeName" "${manifest_source}" \
  "labeler manifest should discover its own node name via downward API"

printf 'PASS: CPU topology labeler checks\n'
