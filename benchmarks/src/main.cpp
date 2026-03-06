/*
 * rubik-pi hardware benchmark
 * ═══════════════════════════
 * Runs actual compute on every hardware subsystem of the QCS6490 SoC:
 *
 *   CPU   — OpenCL (POCL)          SAXPY + MatMul
 *   GPU   — OpenCL (Adreno)        SAXPY + MatMul  +  NV12 DMA-buf fill
 *   NPU   — QNN HTP (Hexagon)      MatMul inference
 *   DSP   — QNN DSP / FastRPC      MatMul + memory probe
 *   VPU   — V4L2 M2M (msm_vidc)   NV12 → H.264 encode  (zero-copy DMA-buf)
 *
 * Zero-copy pipeline demonstrated:
 *   [DMA heap] → GPU fills NV12 → same fd → VPU encodes → H.264 bitstream
 *                                          ↑ no CPU copy involved
 */

#include "common.hpp"
#include "dmabuf.hpp"
#include "ocl_bench.hpp"
#include "qnn_runner.hpp"
#include "vpu_codec.hpp"
#include "fastrpc_probe.hpp"

#include <cstdio>
#include <cstring>
#include <cstdlib>

// Dimensions for the shared NV12 DMA-buf used in the GPU→VPU pipeline.
// Must be 16-pixel aligned for msm_vidc.
static constexpr int NV12_W = 640;
static constexpr int NV12_H = 480;
// msm_vidc may align the NV12 buffer to an internal stride/plane boundary.
// Allocate with a 32 KB headroom so the DMA-buf always satisfies the
// driver's sizeimage requirement reported after VIDIOC_S_FMT.
static constexpr size_t NV12_ALLOC = NV12_W * NV12_H * 2 + 32768;

// ── Print banner ──────────────────────────────────────────────────────────────
static void banner()
{
    printf("\n");
    printf(COL_CYAN COL_BOLD
           "╔══════════════════════════════════════════════════╗\n"
           "║   Rubik Pi 3  —  SoC Hardware Benchmark          ║\n"
           "║   QCS6490 · Cortex-A78/A55 · Adreno 643          ║\n"
           "║   Hexagon 790 (HTP/CDSP) · msm_vidc VPU          ║\n"
           "╚══════════════════════════════════════════════════╝\n"
           COL_RESET "\n");
}

// ── Final results table ───────────────────────────────────────────────────────
static void print_summary()
{
    auto& res = results();
    printf("\n");
    printf(COL_BOLD "══════════════════════════  SUMMARY  "
           "══════════════════════════\n" COL_RESET);
    printf("  %-22s  %-6s  %8s  %s\n",
           "Subsystem", "Result", "ms", "Note");
    printf("  %-22s  %-6s  %8s  %s\n",
           "──────────────────────", "──────", "────────", "──────────────────────");

    int pass = 0, fail = 0;
    for (auto& r : res) {
        const char* sym  = r.ok ? (COL_GREEN "PASS" COL_RESET)
                                : (COL_RED   "FAIL" COL_RESET);
        printf("  %-22s  %s    %7.1f  %s\n",
               r.subsystem.c_str(), sym, r.ms, r.note.c_str());
        r.ok ? pass++ : fail++;
    }
    printf(COL_BOLD "  ──────────────────────────────────────────────────\n");
    printf("  %d passed  /  %d failed  /  %d total\n" COL_RESET,
           pass, fail, pass + fail);

    if (fail == 0)
        printf("\n" COL_GREEN COL_BOLD "  All subsystems operational ✓\n" COL_RESET);
    else
        printf("\n" COL_YELLOW "  Some subsystems had issues (see details above)\n" COL_RESET);

    printf("\n"
           COL_BOLD "  SDK / API references:\n" COL_RESET
           "    CPU    POCL OpenCL, NEON intrinsics, ARM Compute Library\n"
           "    GPU    Adreno OpenCL (libOpenCL_adreno.so), Vulkan (Turnip),\n"
           "           OpenGL ES (libGLESv2)\n"
           "    NPU    Qualcomm AI Engine Direct (QNN), SNPE, ONNX Runtime QNN EP\n"
           "    DSP    QNN DSP backend, FastRPC (libcdsprpc.so), HAP SDK\n"
           "    VPU    V4L2 M2M (msm_vidc), GStreamer v4l2h264enc, FFmpeg v4l2m2m\n"
           "    Mem    DMA-heap (/dev/dma_heap/system) for zero-copy inter-device\n"
           "\n");
}

// ── Entry point ───────────────────────────────────────────────────────────────
int main(int argc, char** argv)
{
    (void)argc; (void)argv;
    banner();

    // ── Allocate the shared NV12 DMA-buf used for the GPU→VPU pipeline ────────
    printf(COL_BOLD "  Allocating NV12 DMA-buf  (%dx%d, %.1f KB)  via /dev/dma_heap/system\n"
           COL_RESET,
           NV12_W, NV12_H, NV12_W * NV12_H * 1.5 / 1024.0);

    // Try qcom,system first (preferred for msm_vidc HW), fall back to generic system heap
    DmaBuf nv12(NV12_ALLOC, "qcom,system");
    if (!nv12.valid())
        nv12 = DmaBuf(NV12_ALLOC, "system");
    if (!nv12.valid()) {
        warn_msg("DMA-buf allocation failed — VPU DMA-buf import disabled");
    } else {
        ok_msg("DMA-buf fd=%d  size=%zu B  →  shared across GPU + VPU",
               nv12.fd(), nv12.size());

        // CPU pre-fill: diagonal luma gradient + neutral chroma.
        // The GPU OpenCL test will overwrite the Y plane if it finds an Adreno
        // platform with cl_arm_import_memory.
        uint8_t* y  = static_cast<uint8_t*>(nv12.ptr());
        uint8_t* uv = y + NV12_W * NV12_H;
        for (int row = 0; row < NV12_H; row++)
            for (int col = 0; col < NV12_W; col++)
                y[row*NV12_W + col] = (uint8_t)(((col + row) * 255) / (NV12_W + NV12_H - 2));
        memset(uv, 128, NV12_W * NV12_H / 2);
        ok_msg("CPU pre-filled NV12 test pattern into DMA-buf");
    }

    // ── OpenCL benchmarks  (CPU + GPU) ────────────────────────────────────────
    run_opencl_benchmarks(nv12.valid() ? nv12.fd() : -1, NV12_W, NV12_H);

    // ── QNN inference  (NPU-HTP, DSP, CPU, GPU backends) ─────────────────────
    run_qnn_benchmarks();

    // ── VPU encode  (V4L2 M2M, zero-copy from DMA-buf) ───────────────────────
    section("VPU  (V4L2 M2M  msm_vidc  NV12 → H.264)");
    if (nv12.valid()) {
        info_msg("Input: DMA-buf fd=%d  (%dx%d NV12)  →  V4L2_MEMORY_DMABUF", nv12.fd(), NV12_W, NV12_H);
        vpu_encode_h264(nv12.fd(), NV12_W, NV12_H);
    } else {
        err_msg("Skipped — DMA-buf not available");
        TestResult r; r.subsystem="VPU-H264"; r.ok=false; r.note="DMA-buf unavailable";
        push_result(r);
    }

    // ── FastRPC probe  (CDSP / ADSP) ─────────────────────────────────────────
    run_fastrpc_probe();

    // ── Summary ───────────────────────────────────────────────────────────────
    print_summary();

    int fail = 0;
    for (auto& r : results()) if (!r.ok) fail++;
    return fail == 0 ? 0 : 1;
}
