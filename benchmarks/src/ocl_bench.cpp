#define CL_TARGET_OPENCL_VERSION 120
#include <CL/cl.h>
#include <CL/cl_ext.h>

#include "ocl_bench.hpp"
#include "common.hpp"
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <sys/mman.h>
#include <vector>
#include <string>

// ── Kernel source ─────────────────────────────────────────────────────────────
static const char* CL_SRC = R"CL(

// SAXPY: y[i] = alpha*x[i] + y[i]
__kernel void saxpy(const float alpha,
                    __global const float* x,
                    __global       float* y) {
    int i = get_global_id(0);
    y[i] = alpha * x[i] + y[i];
}

// Naive MatMul (good for CPU, no shared memory)
__kernel void matmul_naive(__global const float* A,
                           __global const float* B,
                           __global       float* C,
                           const int N) {
    int row = get_global_id(0);
    int col = get_global_id(1);
    float acc = 0.0f;
    for (int k = 0; k < N; k++)
        acc += A[row*N + k] * B[k*N + col];
    C[row*N + col] = acc;
}

// Tiled MatMul — uses __local shared memory (optimal for GPU)
// Tile dimension MUST match local_work_size in both dimensions.
#define TILE 16
__kernel __attribute__((reqd_work_group_size(TILE, TILE, 1)))
void matmul_tiled(__global const float* A,
                  __global const float* B,
                  __global       float* C,
                  const int N) {
    __local float As[TILE][TILE];
    __local float Bs[TILE][TILE];

    int row  = get_global_id(0);
    int col  = get_global_id(1);
    int lrow = get_local_id(0);
    int lcol = get_local_id(1);

    float acc = 0.0f;
    for (int t = 0; t < N / TILE; t++) {
        As[lrow][lcol] = A[row * N + t * TILE + lcol];
        Bs[lrow][lcol] = B[(t * TILE + lrow) * N + col];
        barrier(CLK_LOCAL_MEM_FENCE);
        for (int k = 0; k < TILE; k++)
            acc += As[lrow][k] * Bs[k][lcol];
        barrier(CLK_LOCAL_MEM_FENCE);
    }
    C[row * N + col] = acc;
}

// Fill NV12 Y-plane with diagonal gradient (GPU→VPU pipeline)
__kernel void yuv_fill_y(__global uchar* Y, const int W, const int H) {
    int x = get_global_id(0);
    int y = get_global_id(1);
    if (x < W && y < H)
        Y[y*W + x] = (uchar)(((x + y) * 255) / (W + H - 2));
}

// Fill NV12 UV-plane with neutral chroma
__kernel void yuv_fill_uv(__global uchar* UV, const int W, const int H_UV) {
    int x = get_global_id(0);
    int y = get_global_id(1);
    if (x < W && y < H_UV)
        UV[y*W + x] = 128;
}
)CL";

// ── Helpers ───────────────────────────────────────────────────────────────────
#define CL_CHECK(err, ctx) \
    do { if ((err) != CL_SUCCESS) { \
        err_msg("OpenCL error %d in %s", (int)(err), ctx); \
        goto cleanup; } } while(0)

static std::string device_name(cl_device_id dev) {
    char buf[256] = {};
    clGetDeviceInfo(dev, CL_DEVICE_NAME, sizeof(buf), buf, nullptr);
    return buf;
}
static std::string platform_name(cl_platform_id p) {
    char buf[256] = {};
    clGetPlatformInfo(p, CL_PLATFORM_NAME, sizeof(buf), buf, nullptr);
    return buf;
}

// ── Per-device benchmark ──────────────────────────────────────────────────────
static void bench_device(cl_platform_id platform,
                         cl_device_id   device,
                         int            dma_fd,
                         int            dma_w,
                         int            dma_h)
{
    std::string dname = device_name(device);
    cl_device_type dtype = CL_DEVICE_TYPE_DEFAULT;
    clGetDeviceInfo(device, CL_DEVICE_TYPE, sizeof(dtype), &dtype, nullptr);
    const bool is_gpu = (dtype & CL_DEVICE_TYPE_GPU) != 0;
    const char* kind  = is_gpu ? "GPU-OpenCL" : "CPU-OpenCL";

    // GPU uses larger N and tiled kernel; CPU uses smaller N and naive kernel.
    // Both get the same SAXPY size so bandwidth numbers are comparable.
    const int SAXPY_N = is_gpu ? (32 * 1024 * 1024) : (4 * 1024 * 1024);
    const int MM_N    = is_gpu ? 1024 : 512;

    info_msg("  Platform : %s", platform_name(platform).c_str());
    info_msg("  Device   : %s  [%s]", dname.c_str(), kind);

    cl_int  err;
    cl_context     ctx     = nullptr;
    cl_command_queue cq    = nullptr;
    cl_program     prog    = nullptr;
    cl_kernel      k_saxpy = nullptr;
    cl_kernel      k_mm    = nullptr;   // naive (CPU) or tiled (GPU)
    cl_kernel      k_yuvy  = nullptr, k_yuvuv = nullptr;
    cl_mem   x_buf=nullptr, y_buf=nullptr;
    cl_mem   A_buf=nullptr, B_buf=nullptr, C_buf=nullptr;
    cl_mem   nv12_buf = nullptr;
    void*    nv12_mmap = MAP_FAILED;
    TestResult res;
    res.subsystem = kind;

    cl_context_properties props[] = {
        CL_CONTEXT_PLATFORM, (cl_context_properties)platform, 0 };
    ctx = clCreateContext(props, 1, &device, nullptr, nullptr, &err);
    CL_CHECK(err, "clCreateContext");

    cq = clCreateCommandQueue(ctx, device, 0, &err);
    CL_CHECK(err, "clCreateCommandQueue");

    prog = clCreateProgramWithSource(ctx, 1, &CL_SRC, nullptr, &err);
    CL_CHECK(err, "clCreateProgramWithSource");
    err = clBuildProgram(prog, 1, &device, "-cl-fast-relaxed-math", nullptr, nullptr);
    if (err != CL_SUCCESS) {
        char log[8192] = {};
        clGetProgramBuildInfo(prog, device, CL_PROGRAM_BUILD_LOG,
                              sizeof(log), log, nullptr);
        err_msg("Build failed: %s", log);
        goto cleanup;
    }

    k_saxpy = clCreateKernel(prog, "saxpy",  &err); CL_CHECK(err, "saxpy");
    k_mm    = clCreateKernel(prog, is_gpu ? "matmul_tiled" : "matmul_naive", &err);
    CL_CHECK(err, is_gpu ? "matmul_tiled" : "matmul_naive");
    k_yuvy  = clCreateKernel(prog, "yuv_fill_y",  &err); CL_CHECK(err, "yuv_fill_y");
    k_yuvuv = clCreateKernel(prog, "yuv_fill_uv", &err); CL_CHECK(err, "yuv_fill_uv");

    // ── SAXPY ─────────────────────────────────────────────────────────────────
    {
        std::vector<float> hx(SAXPY_N, 1.0f), hy(SAXPY_N, 2.0f);
        x_buf = clCreateBuffer(ctx, CL_MEM_READ_ONLY  | CL_MEM_COPY_HOST_PTR,
                               (size_t)SAXPY_N*4, hx.data(), &err); CL_CHECK(err, "x_buf");
        y_buf = clCreateBuffer(ctx, CL_MEM_READ_WRITE | CL_MEM_COPY_HOST_PTR,
                               (size_t)SAXPY_N*4, hy.data(), &err); CL_CHECK(err, "y_buf");

        float alpha = 3.0f;
        clSetKernelArg(k_saxpy, 0, sizeof(float),  &alpha);
        clSetKernelArg(k_saxpy, 1, sizeof(cl_mem), &x_buf);
        clSetKernelArg(k_saxpy, 2, sizeof(cl_mem), &y_buf);

        // Warm-up, then reset y_buf for a clean timed run
        size_t gws = (size_t)SAXPY_N;
        clEnqueueNDRangeKernel(cq, k_saxpy, 1, nullptr, &gws, nullptr, 0, nullptr, nullptr);
        clFinish(cq);
        clEnqueueWriteBuffer(cq, y_buf, CL_TRUE, 0, (size_t)SAXPY_N*4, hy.data(),
                             0, nullptr, nullptr);

        Timer t;
        clEnqueueNDRangeKernel(cq, k_saxpy, 1, nullptr, &gws, nullptr, 0, nullptr, nullptr);
        clFinish(cq);
        double ms = t.elapsed_ms();

        float check = 0;
        clEnqueueReadBuffer(cq, y_buf, CL_TRUE, 0, sizeof(float), &check, 0, nullptr, nullptr);
        bool valid = (std::fabs(check - 5.0f) < 1e-3f);

        // 3 memory ops per element (read x, read y, write y)
        double gb = 3.0 * SAXPY_N * 4 / 1e9;
        ok_msg("SAXPY %dM floats: %.2f ms  →  %.1f GB/s  [%s]",
               SAXPY_N/1024/1024, ms, gb/(ms/1000.0), valid?"✓":"MISMATCH");

        clReleaseMemObject(x_buf); x_buf = nullptr;
        clReleaseMemObject(y_buf); y_buf = nullptr;
    }

    // ── MatMul ────────────────────────────────────────────────────────────────
    {
        size_t sz = (size_t)MM_N * MM_N * 4;
        std::vector<float> hA(MM_N*MM_N, 0.0f), hB(MM_N*MM_N);

        // A = identity, B = random-ish; C = A*B should equal B
        for (int i = 0; i < MM_N; i++) hA[i*MM_N+i] = 1.0f;
        for (int i = 0; i < MM_N*MM_N; i++) hB[i] = (float)(i % 13) - 6.0f;

        A_buf = clCreateBuffer(ctx, CL_MEM_READ_ONLY|CL_MEM_COPY_HOST_PTR, sz, hA.data(), &err);
        CL_CHECK(err, "A_buf");
        B_buf = clCreateBuffer(ctx, CL_MEM_READ_ONLY|CL_MEM_COPY_HOST_PTR, sz, hB.data(), &err);
        CL_CHECK(err, "B_buf");
        C_buf = clCreateBuffer(ctx, CL_MEM_WRITE_ONLY, sz, nullptr, &err);
        CL_CHECK(err, "C_buf");

        clSetKernelArg(k_mm, 0, sizeof(cl_mem), &A_buf);
        clSetKernelArg(k_mm, 1, sizeof(cl_mem), &B_buf);
        clSetKernelArg(k_mm, 2, sizeof(cl_mem), &C_buf);
        int N = MM_N;
        clSetKernelArg(k_mm, 3, sizeof(int), &N);

        size_t gws2[2] = { (size_t)MM_N, (size_t)MM_N };
        // GPU: tiled kernel requires local_work_size = {TILE, TILE}
        size_t lws2[2] = { 16, 16 };
        size_t* lws_ptr = is_gpu ? lws2 : nullptr;

        // Warm-up
        clEnqueueNDRangeKernel(cq, k_mm, 2, nullptr, gws2, lws_ptr, 0, nullptr, nullptr);
        clFinish(cq);

        Timer t;
        clEnqueueNDRangeKernel(cq, k_mm, 2, nullptr, gws2, lws_ptr, 0, nullptr, nullptr);
        clFinish(cq);
        double ms = t.elapsed_ms();

        // Verify C == B (since A is identity matrix)
        std::vector<float> hC(MM_N*MM_N);
        clEnqueueReadBuffer(cq, C_buf, CL_TRUE, 0, sz, hC.data(), 0, nullptr, nullptr);
        bool valid = true;
        for (int i = 0; i < MM_N*MM_N && valid; i++)
            if (std::fabs(hC[i] - hB[i]) > 1e-1f) valid = false;

        double gflops = 2.0 * MM_N * MM_N * MM_N / 1e9;
        const char* kernel_label = is_gpu ? "tiled 16×16 local-mem" : "naive";
        ok_msg("MatMul %dx%d (%s): %.2f ms  →  %.1f GFLOP/s  [%s]",
               MM_N, MM_N, kernel_label, ms, gflops/(ms/1000.0), valid?"✓":"MISMATCH");
        res.ms   = ms;
        res.gops = gflops / (ms / 1000.0);
        res.ok   = valid;
        res.note = dname;

        clReleaseMemObject(A_buf); A_buf = nullptr;
        clReleaseMemObject(B_buf); B_buf = nullptr;
        clReleaseMemObject(C_buf); C_buf = nullptr;
    }

    // ── GPU → VPU NV12 fill ───────────────────────────────────────────────────
    // Only run on GPU when a DMA-buf is available.
    // Strategy: create an OCL buffer backed by the DMA-buf's mmap'd address
    // (CL_MEM_USE_HOST_PTR).  Run fill kernels on GPU, then call MapBuffer to
    // flush GPU caches back to the host pointer — which IS the DMA-buf.
    // The Adreno driver flushes GPU→CPU on MapBuffer even for USE_HOST_PTR
    // buffers, so the DMA-buf will contain the GPU-computed NV12 frame.
    if (is_gpu && dma_fd >= 0) {
        size_t yuv_size = (size_t)dma_w * dma_h * 3 / 2;

        // mmap the DMA-buf so we can hand its address to OpenCL as host_ptr
        nv12_mmap = mmap(nullptr, yuv_size, PROT_READ|PROT_WRITE,
                         MAP_SHARED, dma_fd, 0);

        if (nv12_mmap != MAP_FAILED) {
            nv12_buf = clCreateBuffer(ctx,
                CL_MEM_USE_HOST_PTR | CL_MEM_READ_WRITE,
                yuv_size, nv12_mmap, &err);
        }

        if (nv12_buf && err == CL_SUCCESS) {
            // Fill Y-plane
            int W = dma_w, H = dma_h;
            clSetKernelArg(k_yuvy, 0, sizeof(cl_mem), &nv12_buf);
            clSetKernelArg(k_yuvy, 1, sizeof(int),    &W);
            clSetKernelArg(k_yuvy, 2, sizeof(int),    &H);
            size_t gws_y[2] = { (size_t)dma_w, (size_t)dma_h };
            err = clEnqueueNDRangeKernel(cq, k_yuvy, 2, nullptr, gws_y, nullptr,
                                         0, nullptr, nullptr);

            if (err == CL_SUCCESS) {
                // Fill UV-plane via sub-buffer
                cl_buffer_region uv_reg = {
                    (size_t)dma_w * dma_h,
                    (size_t)dma_w * dma_h / 2
                };
                cl_mem uv_buf = clCreateSubBuffer(nv12_buf, CL_MEM_READ_WRITE,
                                                  CL_BUFFER_CREATE_TYPE_REGION,
                                                  &uv_reg, &err);
                if (err == CL_SUCCESS) {
                    int H_UV = dma_h / 2;
                    clSetKernelArg(k_yuvuv, 0, sizeof(cl_mem), &uv_buf);
                    clSetKernelArg(k_yuvuv, 1, sizeof(int),    &W);
                    clSetKernelArg(k_yuvuv, 2, sizeof(int),    &H_UV);
                    size_t gws_uv[2] = { (size_t)dma_w, (size_t)dma_h/2 };
                    clEnqueueNDRangeKernel(cq, k_yuvuv, 2, nullptr, gws_uv, nullptr,
                                           0, nullptr, nullptr);
                    clReleaseMemObject(uv_buf);
                }

                // Flush GPU caches → host_ptr (DMA-buf) via MapBuffer
                void* mapped = clEnqueueMapBuffer(cq, nv12_buf, CL_TRUE,
                                                   CL_MAP_READ, 0, yuv_size,
                                                   0, nullptr, nullptr, &err);
                clEnqueueUnmapMemObject(cq, nv12_buf, mapped, 0, nullptr, nullptr);
                clFinish(cq);

                if (err == CL_SUCCESS) {
                    ok_msg("GPU filled NV12 DMA-buf (%dx%d) via USE_HOST_PTR+MapBuffer "
                           "→ VPU-ready ✓", dma_w, dma_h);
                } else {
                    warn_msg("GPU NV12 fill: MapBuffer flush failed (err=%d) — "
                             "VPU will use CPU-filled buffer", err);
                }
            } else {
                warn_msg("GPU NV12 fill: kernel enqueue failed (err=%d)", err);
            }
        } else {
            warn_msg("GPU NV12 buf: could not create USE_HOST_PTR buffer (err=%d) — "
                     "note: cl_qcom_dmabuf_host_ptr is listed but not fully "
                     "functional on this driver; USE_HOST_PTR+MapBuffer is used instead",
                     err);
        }

        // Unmap regardless (mmap'd for USE_HOST_PTR, not needed anymore after flush)
        if (nv12_mmap != MAP_FAILED) {
            munmap(nv12_mmap, yuv_size);
            nv12_mmap = MAP_FAILED;
        }
    }

    push_result(res);

cleanup:
    if (nv12_mmap != MAP_FAILED) {
        size_t yuv_size = (size_t)dma_w * dma_h * 3 / 2;
        munmap(nv12_mmap, yuv_size);
    }
    if (nv12_buf)  clReleaseMemObject(nv12_buf);
    if (x_buf)     clReleaseMemObject(x_buf);
    if (y_buf)     clReleaseMemObject(y_buf);
    if (A_buf)     clReleaseMemObject(A_buf);
    if (B_buf)     clReleaseMemObject(B_buf);
    if (C_buf)     clReleaseMemObject(C_buf);
    if (k_saxpy)   clReleaseKernel(k_saxpy);
    if (k_mm)      clReleaseKernel(k_mm);
    if (k_yuvy)    clReleaseKernel(k_yuvy);
    if (k_yuvuv)   clReleaseKernel(k_yuvuv);
    if (prog)      clReleaseProgram(prog);
    if (cq)        clReleaseCommandQueue(cq);
    if (ctx)       clReleaseContext(ctx);
}

// ── Public entry point ─────────────────────────────────────────────────────────
bool run_opencl_benchmarks(int dma_fd, int dma_width, int dma_height)
{
    section("OpenCL  (CPU + GPU)");

    cl_uint np = 0;
    clGetPlatformIDs(0, nullptr, &np);
    if (np == 0) {
        err_msg("No OpenCL platforms found");
        return false;
    }

    std::vector<cl_platform_id> platforms(np);
    clGetPlatformIDs(np, platforms.data(), nullptr);

    bool any_ok = false;
    for (auto plat : platforms) {
        cl_uint nd = 0;
        clGetDeviceIDs(plat, CL_DEVICE_TYPE_ALL, 0, nullptr, &nd);
        if (nd == 0) continue;

        std::vector<cl_device_id> devs(nd);
        clGetDeviceIDs(plat, CL_DEVICE_TYPE_ALL, nd, devs.data(), nullptr);

        for (auto dev : devs) {
            bench_device(plat, dev, dma_fd, dma_width, dma_height);
            any_ok = true;
        }
    }
    return any_ok;
}
