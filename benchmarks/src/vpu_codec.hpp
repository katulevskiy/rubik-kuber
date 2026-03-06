#pragma once
#include "common.hpp"

// Encode one NV12 frame → H.264 using the msm_vidc M2M encoder.
//
// dma_fd    : file descriptor of an NV12 DMA-buf  (from DmaBuf class)
//             The caller is responsible for filling Y and UV planes before
//             calling this function.
// width/height: frame dimensions (must be 16-pixel aligned for msm_vidc)
//
// Returns true on success.  The encoded bitstream size and latency are
// reported via push_result().
bool vpu_encode_h264(int dma_fd, int width, int height);
