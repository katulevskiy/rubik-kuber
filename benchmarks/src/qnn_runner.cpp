#include "qnn_runner.hpp"
#include "common.hpp"

#include <QnnInterface.h>
#include <QnnOpDef.h>
#include <QnnTypes.h>
#include <QnnLog.h>

#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <cmath>
#include <cstring>
#include <cstdlib>
#include <vector>
#include <string>
#include <algorithm>

// ── Typedefs ─────────────────────────────────────────────────────────────────
typedef Qnn_ErrorHandle_t (*QnnGetProvidersFn_t)(const QnnInterface_t***, uint32_t*);
typedef Qnn_ErrorHandle_t (*QnnLogCreate_t)(QnnLog_Callback_t, QnnLog_Level_t, Qnn_LogHandle_t*);

// Access to the versioned implementation struct field
#define QNN_IFACE(p) ((p)->v2_30)

// ── Quiet log callback ────────────────────────────────────────────────────────
// Silences QNN's own log-callback system (structured logging).
static void qnn_log_cb(const char* /*fmt*/, QnnLog_Level_t lvl,
                       uint64_t /*stamp*/, va_list /*ap*/) {
    (void)lvl;
}

// ── Library noise filter ──────────────────────────────────────────────────────
// QNN backend shared libraries (libQnnHtp.so, libQnnHtpPrepare.so,
// libxdsprpc.so, rpcmem) emit verbose diagnostics directly via printf/fprintf
// to BOTH stdout and stderr, bypassing the QNN log callback entirely.  Examples:
//   <W> Initializing HtpProvider
//   rpcmem_android.c:38: dummy call to rpcmem_init ...
//   <W> Sanitizing the value for hvx_threads and setting to default
//   ====== DDR bandwidth summary ======
//   <W> m_CFBCallbackInfoObj is not initialized, return emptyList
// We redirect BOTH fd 1 (stdout) and fd 2 (stderr) to /dev/null for the
// duration of QNN backend calls, then restore them before our own output.
struct LibNoiseFilter {
    int saved_out;
    int saved_err;

    explicit LibNoiseFilter() : saved_out(-1), saved_err(-1) {
        fflush(stdout);
        fflush(stderr);
        saved_out = dup(STDOUT_FILENO);
        saved_err = dup(STDERR_FILENO);
        int nul = open("/dev/null", O_WRONLY);
        if (nul >= 0) {
            dup2(nul, STDOUT_FILENO);
            dup2(nul, STDERR_FILENO);
            close(nul);
        }
    }

    // Idempotent — safe to call explicitly before the destructor runs.
    void restore() {
        if (saved_out >= 0) {
            fflush(stdout);
            dup2(saved_out, STDOUT_FILENO);
            close(saved_out);
            saved_out = -1;
        }
        if (saved_err >= 0) {
            fflush(stderr);
            dup2(saved_err, STDERR_FILENO);
            close(saved_err);
            saved_err = -1;
        }
    }

    ~LibNoiseFilter() { restore(); }
};

// ── Reference CPU MatMul ──────────────────────────────────────────────────────
static void ref_matmul(const float* A, const float* B, float* C, int N) {
    for (int r = 0; r < N; r++)
        for (int c = 0; c < N; c++) {
            float s = 0;
            for (int k = 0; k < N; k++) s += A[r*N+k] * B[k*N+c];
            C[r*N+c] = s;
        }
}

// ── Build + execute a single-MatMul graph on a QNN backend ──────────────────
static bool run_backend(const char* lib_path,
                        const char* display_name,
                        int         N)
{
    // Generate inputs and reference output for this backend's matrix size.
    std::vector<float> h_A(N*N), h_B(N*N), h_Cref(N*N, 0.0f);
    for (int i = 0; i < N*N; i++) {
        h_A[i] = (float)(i % 13) * 0.1f;
        h_B[i] = (float)(i % 7)  * 0.1f;
    }
    ref_matmul(h_A.data(), h_B.data(), h_Cref.data(), N);

    // Redirect both stdout and stderr to /dev/null for the lifetime of this
    // backend.  QNN libraries emit verbose diagnostics directly to fd 1/2.
    LibNoiseFilter _quiet;

    // ── 1. Load shared library ───────────────────────────────────────────────
    void* dl = dlopen(lib_path, RTLD_NOW | RTLD_LOCAL);
    if (!dl) {
        _quiet.restore();
        warn_msg("%-18s  dlopen failed: %s", display_name, dlerror());
        return false;
    }

    auto getProviders = (QnnGetProvidersFn_t)dlsym(dl, "QnnInterface_getProviders");
    if (!getProviders) {
        dlclose(dl);
        _quiet.restore();
        warn_msg("%-18s  QnnInterface_getProviders not found", display_name);
        return false;
    }

    // ── 2. Get interface ─────────────────────────────────────────────────────
    const QnnInterface_t** providers = nullptr;
    uint32_t               nProviders = 0;
    if (getProviders(&providers, &nProviders) != QNN_SUCCESS || nProviders == 0) {
        dlclose(dl);
        _quiet.restore();
        warn_msg("%-18s  getProviders returned no interface", display_name);
        return false;
    }
    const QnnInterface_t* iface = providers[0];

    // ── 3. Log handle ────────────────────────────────────────────────────────
    Qnn_LogHandle_t log_h = nullptr;
    auto createLog = (QnnLogCreate_t)dlsym(dl, "QnnLog_create");
    if (createLog)
        createLog(qnn_log_cb, QNN_LOG_LEVEL_ERROR, &log_h);

    // ── 4. Backend ───────────────────────────────────────────────────────────
    Qnn_BackendHandle_t backend = nullptr;
    Qnn_ErrorHandle_t   err;

    err = QNN_IFACE(iface).backendCreate(log_h, nullptr, &backend);
    if (err != QNN_SUCCESS) {
        dlclose(dl);
        _quiet.restore();
        warn_msg("%-18s  backendCreate failed (0x%08x)", display_name, (unsigned)err);
        return false;
    }

    // ── 5. Context ───────────────────────────────────────────────────────────
    Qnn_ContextHandle_t ctx = nullptr;
    err = QNN_IFACE(iface).contextCreate(backend, nullptr, nullptr, &ctx);
    if (err != QNN_SUCCESS) {
        QNN_IFACE(iface).backendFree(backend);
        dlclose(dl);
        _quiet.restore();
        warn_msg("%-18s  contextCreate failed (0x%08x)", display_name, (unsigned)err);
        return false;
    }

    // ── 6. Graph ─────────────────────────────────────────────────────────────
    Qnn_GraphHandle_t graph = nullptr;
    err = QNN_IFACE(iface).graphCreate(ctx, "matmul_test", nullptr, &graph);
    if (err != QNN_SUCCESS) {
        _quiet.restore();
        warn_msg("%-18s  graphCreate failed (0x%08x)", display_name, (unsigned)err);
        goto free_ctx;
    }

    // ── 7. Tensors ───────────────────────────────────────────────────────────
    {
        size_t   sz   = (size_t)N * N * sizeof(float);
        uint32_t dims[2] = { (uint32_t)N, (uint32_t)N };

        // Input A  (QNN_TENSOR_TYPE_APP_WRITE = fed by application at execute-time)
        // NOTE: clientBuf.data must be nullptr at tensor creation time;
        //       actual data pointers are bound at graphExecute() time.
        Qnn_Tensor_t tA = QNN_TENSOR_INIT;
        tA.version   = QNN_TENSOR_VERSION_1;
        tA.v1.name   = "input_A";
        tA.v1.type   = QNN_TENSOR_TYPE_APP_WRITE;
        tA.v1.dataFormat    = QNN_TENSOR_DATA_FORMAT_FLAT_BUFFER;
        tA.v1.dataType      = QNN_DATATYPE_FLOAT_32;
        tA.v1.quantizeParams.encodingDefinition  = QNN_DEFINITION_UNDEFINED;
        tA.v1.quantizeParams.quantizationEncoding= QNN_QUANTIZATION_ENCODING_UNDEFINED;
        tA.v1.rank       = 2;
        tA.v1.dimensions = dims;
        tA.v1.memType    = QNN_TENSORMEMTYPE_RAW;
        tA.v1.clientBuf  = { nullptr, (uint32_t)sz };  // null at creation

        err = QNN_IFACE(iface).tensorCreateGraphTensor(graph, &tA);
        if (err != QNN_SUCCESS) {
            warn_msg("%-18s  tensor input_A failed (0x%08x)", display_name, (unsigned)err);
            goto free_ctx;
        }

        // Input B
        Qnn_Tensor_t tB = tA;
        tB.v1.name = "input_B";
        tB.v1.clientBuf = { nullptr, (uint32_t)sz };
        err = QNN_IFACE(iface).tensorCreateGraphTensor(graph, &tB);
        if (err != QNN_SUCCESS) {
            warn_msg("%-18s  tensor input_B failed (0x%08x)", display_name, (unsigned)err);
            goto free_ctx;
        }

        // Output C  (QNN_TENSOR_TYPE_APP_READ = written by graph, read by application)
        std::vector<float> h_C(N * N, 0.0f);
        Qnn_Tensor_t tC = tA;
        tC.v1.name = "output_C";
        tC.v1.type = QNN_TENSOR_TYPE_APP_READ;
        tC.v1.clientBuf = { nullptr, (uint32_t)sz };  // null at creation
        err = QNN_IFACE(iface).tensorCreateGraphTensor(graph, &tC);
        if (err != QNN_SUCCESS) {
            warn_msg("%-18s  tensor output_C failed (0x%08x)", display_name, (unsigned)err);
            goto free_ctx;
        }

        // ── 8. MatMul Op ──────────────────────────────────────────────────────
        Qnn_Tensor_t op_in[2]  = { tA, tB };
        Qnn_Tensor_t op_out[1] = { tC };

        Qnn_OpConfigV1_t op_v1{};
        op_v1.name         = "matmul_0";
        op_v1.packageName  = QNN_OP_PACKAGE_NAME_QTI_AISW;
        op_v1.typeName     = QNN_OP_MAT_MUL;
        op_v1.numOfInputs  = 2;
        op_v1.inputTensors = op_in;
        op_v1.numOfOutputs = 1;
        op_v1.outputTensors= op_out;

        Qnn_OpConfig_t op{};
        op.version = QNN_OPCONFIG_VERSION_1;
        op.v1      = op_v1;

        err = QNN_IFACE(iface).graphAddNode(graph, op);
        if (err != QNN_SUCCESS) {
            _quiet.restore();
            warn_msg("%-18s  graphAddNode failed (0x%08x)", display_name, (unsigned)err);
            goto free_ctx;
        }

        // ── 9. Finalize ──────────────────────────────────────────────────────
        err = QNN_IFACE(iface).graphFinalize(graph, nullptr, nullptr);
        if (err != QNN_SUCCESS) {
            _quiet.restore();
            warn_msg("%-18s  graphFinalize failed (0x%08x)", display_name, (unsigned)err);
            goto free_ctx;
        }

        // ── 10. Execute (timed) ───────────────────────────────────────────────
        Qnn_Tensor_t exec_in[2]  = { tA, tB };
        Qnn_Tensor_t exec_out[1] = { tC };
        exec_in[0].v1.clientBuf.data      = h_A.data();
        exec_in[0].v1.clientBuf.dataSize  = (uint32_t)sz;
        exec_in[1].v1.clientBuf.data      = h_B.data();
        exec_in[1].v1.clientBuf.dataSize  = (uint32_t)sz;
        exec_out[0].v1.clientBuf.data     = h_C.data();
        exec_out[0].v1.clientBuf.dataSize = (uint32_t)sz;

        // Warm-up (stderr silenced — HTP prints DDR bandwidth summary here)
        QNN_IFACE(iface).graphExecute(graph, exec_in, 2, exec_out, 1, nullptr, nullptr);

        Timer t;
        err = QNN_IFACE(iface).graphExecute(graph, exec_in, 2, exec_out, 1, nullptr, nullptr);
        double ms = t.elapsed_ms();

        if (err != QNN_SUCCESS) {
            _quiet.restore();
            warn_msg("%-18s  graphExecute failed (0x%08x)", display_name, (unsigned)err);
            goto free_ctx;
        }

        // ── 11. Verify ────────────────────────────────────────────────────────
        float max_err = 0;
        for (int i = 0; i < N*N; i++)
            max_err = std::max(max_err, std::fabs(h_C[i] - h_Cref[i]));
        bool valid = (max_err < 1e-2f * N);

        double gflops = 2.0 * N * N * N / 1e9;

        // Teardown while stdout/stderr are still silenced (libraries print on cleanup too)
        QNN_IFACE(iface).contextFree(ctx, nullptr);
        QNN_IFACE(iface).backendFree(backend);
        dlclose(dl);

        // Restore stdout/stderr before printing our own result
        _quiet.restore();

        if (valid) {
            ok_msg("%-18s  %dx%d MatMul: %.2f ms  →  %.1f GFLOP/s  [max_err %.2e] ✓",
                   display_name, N, N, ms, gflops/(ms/1000.0), (double)max_err);
        } else {
            warn_msg("%-18s  %dx%d MatMul: %.2f ms  max_err=%.2e  (MISMATCH)",
                     display_name, N, N, ms, (double)max_err);
        }

        TestResult res;
        res.subsystem = display_name;
        res.ok   = valid;
        res.ms   = ms;
        res.gops = gflops / (ms / 1000.0);
        res.note = std::string(lib_path) + " — " + (valid?"pass":"mismatch");
        push_result(res);
        return valid;
    }

free_ctx:
    QNN_IFACE(iface).contextFree(ctx, nullptr);
    QNN_IFACE(iface).backendFree(backend);
    dlclose(dl);
    _quiet.restore();
    return false;
}

// ── Public entry point ────────────────────────────────────────────────────────
void run_qnn_benchmarks()
{
    section("QNN Inference  (CPU / NPU-HTP / GPU)");

    // QNN is a unified inference API with multiple hardware backends.
    // Each backend routes the same model graph to different silicon:
    //
    //   QNN-CPU  — executes on the ARM CPU cores (Cortex-A78/A55) in software.
    //              Good baseline; same correctness path as the reference.
    //
    //   QNN-HTP  — Hexagon Tensor Processor.  This IS the NPU / AI Engine
    //              on the CDSP.  Communicates via FastRPC (libxdsprpc),
    //              compiles the graph to Hexagon binary on first run.
    //              Optimised for large models; the fixed FastRPC round-trip
    //              overhead (~1 ms) dominates tiny inputs.  Use 512×512 to
    //              amortise that overhead and see real throughput.
    //
    //   QNN-GPU  — Adreno 643L GPU via OpenCL compute shaders.
    //              Faster than CPU for large matrices; lower peak than HTP.
    //
    // libQnnDsp.so (legacy ADSP compute DSP) is excluded — not supported on
    // QCS6490 (AI compute moved to HTP on the CDSP with the Hexagon 690+).

    struct { const char* lib; const char* name; int N; } backends[] = {
        { "/usr/lib/libQnnCpu.so", "QNN-CPU",      64  },
        { "/usr/lib/libQnnHtp.so", "QNN-HTP (NPU)", 512 },
        { "/usr/lib/libQnnGpu.so", "QNN-GPU",      128 },
    };

    for (auto& b : backends)
        run_backend(b.lib, b.name, b.N);
}
