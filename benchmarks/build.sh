#!/usr/bin/env bash
# Build the hardware benchmark.
# Can be run two ways:
#   1. Directly on the host (recommended — QNN, FastRPC libs are on host)
#   2. Inside the Adreno OpenCL Docker container for GPU OpenCL support
#
# Usage:
#   ./build.sh           — host build (default)
#   ./build.sh --docker  — build inside the Docker image that has Adreno ICD
set -euo pipefail
cd "$(dirname "$0")"

DOCKER_IMAGE="ghcr.io/kastnerrg/cse160-opencl:gpu-adreno"
BUILD_DIR="build"

host_build() {
    echo "==> Installing build dependencies (if missing)…"
    sudo apt-get install -y -qq \
        cmake g++ \
        ocl-icd-opencl-dev opencl-headers \
        pocl-opencl-icd 2>&1 | grep -E "newly|already" || true

    echo "==> Configuring…"
    cmake -S . -B "${BUILD_DIR}" -DCMAKE_BUILD_TYPE=Release

    echo "==> Building…"
    cmake --build "${BUILD_DIR}" -j"$(nproc)"

    echo ""
    echo "Build complete:  ${BUILD_DIR}/hw_bench"
    echo ""
    echo "Run with:        sudo ${BUILD_DIR}/hw_bench"
    echo "Or in Docker:    ./run.sh"
}

docker_build() {
    echo "==> Building inside Docker (Adreno OpenCL available)…"
    # Mount the project root into the container and build
    docker run --rm \
        -v "$(pwd):/workspace/benchmarks" \
        -w /workspace/benchmarks \
        "${DOCKER_IMAGE}" \
        bash -c "
            apt-get install -y -qq cmake ocl-icd-opencl-dev 2>/dev/null | tail -2
            cmake -S . -B build_docker -DCMAKE_BUILD_TYPE=Release
            cmake --build build_docker -j\$(nproc)
            echo 'Docker build → build_docker/hw_bench'
        "
}

if [[ "${1:-}" == "--docker" ]]; then
    docker_build
else
    host_build
fi
