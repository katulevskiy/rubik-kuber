#pragma once
#include "common.hpp"

// Run QNN MatMul inference on each available QNN backend.
// Each backend tests a different piece of silicon with a matrix size chosen
// to amortise that hardware's fixed dispatch overhead:
//
//   QNN-CPU  (libQnnCpu.so)  — ARM CPU,        64×64 float32
//   QNN-HTP  (libQnnHtp.so)  — Hexagon HTP/NPU, 512×512 float32
//   QNN-GPU  (libQnnGpu.so)  — Adreno 643L GPU, 128×128 float32
//
// libQnnDsp.so (legacy ADSP compute) is excluded — not supported on QCS6490.
void run_qnn_benchmarks();
