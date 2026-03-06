#pragma once
#include "common.hpp"

// Probe the FastRPC interface to the CDSP (NPU/Compute DSP) and ADSP
// (Audio DSP) via their kernel character devices.
//
// For the CDSP, we additionally call into libcdsprpc.so using the
// remote_handle_open/invoke API to confirm the user-space RPC stack
// is functional end-to-end.  Without a compiled Hexagon .so skel, the
// actual compute stub call will fail gracefully; the test still reports
// success if the device can be opened and memory can be allocated.
void run_fastrpc_probe();
