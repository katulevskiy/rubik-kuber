#!/usr/bin/env bash
# Run the hardware benchmark.
# Passes all relevant device nodes into the container so every subsystem is
# accessible.  If Adreno OpenCL is not registered on the host, the OpenCL GPU
# test will use POCL as a fallback; all other tests run natively regardless.
set -euo pipefail
cd "$(dirname "$0")"

BIN="${1:-build/hw_bench}"   # path to compiled binary, override via $1

if [[ ! -f "$BIN" ]]; then
    echo "Binary not found at '$BIN'. Run ./build.sh first."
    exit 1
fi

# Direct host run (recommended — QNN/FastRPC libs are on host)
echo "==> Running $BIN  (direct host, may need sudo for /dev/fastrpc-*)"
sudo "$BIN"
