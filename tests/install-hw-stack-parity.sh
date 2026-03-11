#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="${ROOT_DIR}/install.sh"

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

assert_not_contains() {
  local needle="$1"
  local haystack="$2"
  local message="$3"
  [[ "${haystack}" != *"${needle}"* ]] || fail "${message}: unexpectedly found '${needle}'"
}

install_source="$(<"${INSTALL_SH}")"

assert_not_contains $'    ocl-icd-opencl-dev \\' "${install_source}" \
  "installer should avoid installing the generic OpenCL ICD dev package that broke Adreno on rubik2"

assert_contains "apt-get remove -y -qq ocl-icd-opencl-dev ocl-icd-libopencl1 clinfo" "${install_source}" \
  "installer should remove the stale generic OpenCL ICD packages during repair"

assert_contains "linux-image-qcom" "${install_source}" \
  "installer should install the qcom kernel metapackage for GPU parity"

assert_contains "/etc/OpenCL/vendors/adreno.icd" "${install_source}" \
  "installer should materialize the Adreno ICD file"

assert_contains "libOpenCL_adreno.so.1" "${install_source}" \
  "installer should point the Adreno ICD at the Qualcomm OpenCL runtime"

assert_contains "usermod -aG render" "${install_source}" \
  "installer should add the invoking user to the render group"

printf 'PASS: installer hardware stack parity checks\n'
