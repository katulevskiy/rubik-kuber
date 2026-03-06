#pragma once
#include "common.hpp"

// Run QNN MatMul inference on each available QNN backend:
//   • libQnnCpu.so   — ARM CPU via QNN (quantised reference)
//   • libQnnHtp.so   — Hexagon HTP (NPU / AI Engine)
//   • libQnnDsp.so   — Hexagon DSP (CDSP, general compute)
//   • libQnnGpu.so   — Adreno GPU via QNN (compare w/ raw OpenCL)
//
// Each test builds a single MatMul op graph (N×N float32),
// executes it, and verifies correctness vs. CPU reference.
void run_qnn_benchmarks(int matmul_n = 64);
