#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${ROOT_DIR}/install.sh"
README_MD="${ROOT_DIR}/README.md"
INSTRUCTIONS_MD="${ROOT_DIR}/INSTRUCTIONS.md"

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
readme_source="$(<"${README_MD}")"
instructions_source="$(<"${INSTRUCTIONS_MD}")"

assert_contains 'INSTALL_VERBOSE="${INSTALL_VERBOSE:-0}"' "${install_source}" \
  "installer should expose INSTALL_VERBOSE with a default"

assert_contains 'run_with_progress()' "${install_source}" \
  "installer should define the clean progress wrapper"

assert_contains 'run_shell_with_progress()' "${install_source}" \
  "installer should define the shell progress wrapper"

assert_contains 'wait_status()' "${install_source}" \
  "installer should define wait heartbeat messaging"

assert_contains 'run_with_progress "Installing base system packages"' "${install_source}" \
  "installer should use progress wrappers for package installation"

assert_contains 'run_shell_with_progress "Installing Helm"' "${install_source}" \
  "installer should use progress wrappers for Helm installation"

assert_contains 'run_shell_with_progress "Downloading and installing RKE2' "${install_source}" \
  "installer should use progress wrappers for the RKE2 install"

assert_contains 'parse_cli_args()' "${install_source}" \
  "installer should define CLI parsing for retry mode"

assert_contains 'RETRY_JOIN=0' "${install_source}" \
  "installer should define retry mode state"

assert_contains 'sudo ./install.sh --retry' "${readme_source}" \
  "README should document retry recovery mode"

assert_contains 'sudo ./install.sh --retry' "${instructions_source}" \
  "INSTRUCTIONS should document retry recovery mode"

assert_contains 'INSTALL_VERBOSE=1 sudo ./install.sh' "${readme_source}" \
  "README should document verbose installer mode"

assert_contains 'INSTALL_VERBOSE=1 sudo ./install.sh' "${instructions_source}" \
  "INSTRUCTIONS should document verbose installer mode"

printf 'PASS: installer progress UI checks\n'
