#pragma once
#include "common.hpp"

// Run OpenCL benchmarks and pipeline steps.
// For each device type (CL_DEVICE_TYPE_CPU, CL_DEVICE_TYPE_GPU) that exists
// in any installed platform, we run:
//   • SAXPY  (4 M floats)  — bandwidth-bound
//   • MatMul (512×512 f32) — compute-bound
//
// GPU pipeline step: if cl_arm_import_memory is supported, the GPU fills an
// NV12 DMA-buf (passed as dma_fd + size) with a synthetic test pattern in
// the Y-plane and a uniform chroma in the UV-plane.  The returned fd is then
// usable as V4L2_MEMORY_DMABUF input to the VPU encoder (zero-copy).
//
// Returns true if at least one device passed.
bool run_opencl_benchmarks(int dma_fd, int dma_width, int dma_height);
