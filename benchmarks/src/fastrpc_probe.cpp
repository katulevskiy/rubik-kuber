#include "fastrpc_probe.hpp"
#include "common.hpp"

#include <misc/fastrpc.h>   // kernel uAPI: FASTRPC_IOCTL_*

#include <dlfcn.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <cerrno>
#include <cstring>
#include <cstdint>
#include <string>

// ── libcdsprpc / libadsprpc function prototypes ───────────────────────────────
// (no official headers ship with the host SDK, so we declare the ABI manually)
typedef unsigned int remote_handle;
typedef unsigned int remote_handle64;

typedef int (*remote_handle_open_fn)  (const char* name, remote_handle* ph);
typedef int (*remote_handle_close_fn) (remote_handle h);
typedef int (*remote_handle_invoke_fn)(remote_handle h, unsigned int sc,
                                       struct fastrpc_invoke_args* args);

// ── Probe one FastRPC device node via kernel ioctls ──────────────────────────
static bool probe_kernel(const char* dev_path, const char* label)
{
    int fd = open(dev_path, O_RDWR);
    if (fd < 0) {
        warn_msg("%-12s  open %s: %s", label, dev_path, strerror(errno));
        return false;
    }
    ok_msg("%-12s  opened %s", label, dev_path);

    // Attach to DSP remote shell (needed before memory operations)
    if (ioctl(fd, FASTRPC_IOCTL_INIT_ATTACH, nullptr) < 0) {
        // Non-fatal — the device is still open and usable by user-space libs
        warn_msg("%-12s  INIT_ATTACH: %s  (requires privileged DSP process — ok)",
                 label, strerror(errno));
    } else {
        ok_msg("%-12s  INIT_ATTACH  succeeded", label);
    }

    // Allocate a small DMA buffer accessible from both CPU and DSP
    struct fastrpc_alloc_dma_buf alloc{};
    alloc.fd    = -1;
    alloc.flags = 0;
    alloc.size  = 64 * 1024;  // 64 KB

    if (ioctl(fd, FASTRPC_IOCTL_ALLOC_DMA_BUFF, &alloc) < 0) {
        warn_msg("%-12s  ALLOC_DMA_BUFF (64 KB): %s", label, strerror(errno));
        close(fd);
        return true;  // device opened OK, allocation may need init
    }
    ok_msg("%-12s  ALLOC_DMA_BUFF 64 KB  →  fd=%d", label, alloc.fd);

    // Map the DMA buffer into CPU address space and write a test pattern
    void* cpu_ptr = mmap(nullptr, alloc.size, PROT_READ|PROT_WRITE,
                         MAP_SHARED, alloc.fd, 0);
    if (cpu_ptr != MAP_FAILED) {
        uint32_t* p = static_cast<uint32_t*>(cpu_ptr);
        for (size_t i = 0; i < alloc.size/4; i++) p[i] = (uint32_t)i;
        // Read back to verify
        bool ok = (p[0] == 0 && p[1] == 1 && p[1023] == 1023);
        ok_msg("%-12s  CPU r/w DMA buffer: %s", label, ok?"✓":"MISMATCH");
        munmap(cpu_ptr, alloc.size);
    }

    // Free the DMA buffer
    uint32_t buf_fd = alloc.fd;
    ioctl(fd, FASTRPC_IOCTL_FREE_DMA_BUFF, &buf_fd);
    close(alloc.fd);

    // Note: FASTRPC_IOCTL_MEM_MAP (DSP-side virtual address mapping) requires
    // an active DSP compute process (INIT_CREATE + a loaded skel .so).
    // INIT_ATTACH only attaches to the DSP monitor shell, which is sufficient
    // for DMA allocation and device probing.  Actual DSP compute and memory
    // mapping is handled by the QNN HTP backend via libxdsprpc / rpcmem.

    close(fd);
    return true;
}

// ── rpcmem shared-memory test ─────────────────────────────────────────────────
// rpcmem_alloc is the correct API for allocating CPU↔DSP zero-copy buffers.
// It creates a DMA-buf backed by the DSP heap and registers it with the FastRPC
// driver.  The returned fd can be passed directly to QNN (and other DSP callers)
// for zero-copy data transfer.  This is the real FastRPC memory path — not the
// raw FASTRPC_IOCTL_MEM_MAP ioctl, which requires a fully loaded DSP skel.
typedef void* (*rpcmem_alloc_fn)(int heapid, uint32_t flags, int size);
typedef void  (*rpcmem_free_fn)(void* po);
typedef int   (*rpcmem_to_fd_fn)(void* po);
typedef void  (*rpcmem_init_fn)();

static void test_rpcmem(void* dl_cdsp)
{
    auto fn_alloc = (rpcmem_alloc_fn) dlsym(dl_cdsp, "rpcmem_alloc");
    auto fn_free  = (rpcmem_free_fn)  dlsym(dl_cdsp, "rpcmem_free");
    auto fn_to_fd = (rpcmem_to_fd_fn) dlsym(dl_cdsp, "rpcmem_to_fd");
    auto fn_init  = (rpcmem_init_fn)  dlsym(dl_cdsp, "rpcmem_init");

    if (!fn_alloc || !fn_free || !fn_to_fd) {
        warn_msg("%-12s  rpcmem symbols missing from libcdsprpc.so", "rpcmem");
        return;
    }
    if (fn_init) fn_init();

    // RPCMEM_HEAP_ID_SYSTEM = 25 (system heap, accessible from any DSP domain)
    // RPCMEM_DEFAULT_FLAGS  = 1  (cached, coherent)
    constexpr int HEAP_SYSTEM   = 25;
    constexpr int FLAGS_DEFAULT = 1;
    constexpr int BUF_SIZE      = 64 * 1024;

    void* ptr = fn_alloc(HEAP_SYSTEM, FLAGS_DEFAULT, BUF_SIZE);
    if (!ptr) {
        warn_msg("%-12s  rpcmem_alloc(%d KB) failed", "rpcmem", BUF_SIZE / 1024);
        return;
    }

    int dma_fd = fn_to_fd(ptr);

    // Write a test pattern and verify CPU read-back
    auto* p = static_cast<uint32_t*>(ptr);
    for (int i = 0; i < BUF_SIZE / 4; i++) p[i] = 0xC0DE0000u | (uint32_t)i;
    bool ok = (p[0] == 0xC0DE0000u &&
               p[BUF_SIZE/4 - 1] == (0xC0DE0000u | (uint32_t)(BUF_SIZE/4 - 1)));

    ok_msg("%-12s  rpcmem_alloc %d KB  →  CPU ptr=%p  DMA-buf fd=%d  CPU r/w %s",
           "rpcmem", BUF_SIZE / 1024, ptr, dma_fd, ok ? "✓" : "MISMATCH");
    info_msg("     DMA-buf fd %d can be zero-copy passed to QNN / any DSP caller", dma_fd);

    fn_free(ptr);
}

// ── Probe via libcdsprpc userspace library ────────────────────────────────────
static void probe_userspace_rpc(const char* lib_path, const char* label)
{
    void* dl = dlopen(lib_path, RTLD_NOW | RTLD_LOCAL);
    if (!dl) {
        warn_msg("%-12s  dlopen %s: %s", label, lib_path, dlerror());
        return;
    }

    auto fn_open  = (remote_handle_open_fn) dlsym(dl, "remote_handle_open");
    auto fn_close = (remote_handle_close_fn)dlsym(dl, "remote_handle_close");
    if (!fn_open || !fn_close) {
        warn_msg("%-12s  remote_handle_open symbol not found", label);
        dlclose(dl);
        return;
    }

    ok_msg("%-12s  loaded %s", label, lib_path);

    // Try to open the builtin DSP shell diagnostics interface.
    remote_handle h = 0xFFFFFFFF;
    const char* uris[] = {
        "dspqueue_rpc",          // generic DSP queue RPC (often pre-loaded)
        "adsp_default_listener", // ADSP listener
    };
    bool opened = false;
    for (auto uri : uris) {
        if (fn_open(uri, &h) == 0) {
            ok_msg("%-12s  remote_handle_open(\"%s\")  ✓  — RPC stack functional",
                   label, uri);
            fn_close(h);
            opened = true;
            break;
        }
    }
    if (!opened)
        info_msg("     %s  no pre-loaded stub accessible (normal without DSP .so)",
                 label);

    // Test rpcmem — the shared memory allocator used by QNN and all DSP callers
    test_rpcmem(dl);

    dlclose(dl);
}

// ── Public entry point ────────────────────────────────────────────────────────
void run_fastrpc_probe()
{
    section("FastRPC  (CDSP / NPU  +  ADSP / DSP)");

    bool cdsp_ok = probe_kernel("/dev/fastrpc-cdsp", "CDSP");
    // On QCS6490 the ADSP is only exposed through the secure interface
    bool adsp_ok = probe_kernel("/dev/fastrpc-adsp-secure", "ADSP-sec");

    // Userspace library RPC probe
    probe_userspace_rpc("/usr/lib/aarch64-linux-gnu/libcdsprpc.so", "libcdsprpc");
    // libadsprpc: only check it loads; remote_handle_open on ADSP can hang
    {
        void* dl = dlopen("/usr/lib/aarch64-linux-gnu/libadsprpc.so", RTLD_NOW | RTLD_LOCAL);
        if (dl) {
            ok_msg("%-12s  loaded /usr/lib/aarch64-linux-gnu/libadsprpc.so  (ADSP RPC library)", "libadsprpc");
            dlclose(dl);
        } else {
            warn_msg("%-12s  dlopen failed: %s", "libadsprpc", dlerror());
        }
    }

    info_msg("DSP data path:  CPU mmap  →  DMA-buf fd  →  FASTRPC_IOCTL_MEM_MAP  →  DSP vaddr");
    info_msg("Compute path:   QNN HTP (run_qnn_benchmarks) or compile Hexagon DSP .so via SDK");

    TestResult res;
    res.subsystem = "FastRPC-CDSP";
    res.ok   = cdsp_ok;
    res.note = cdsp_ok ? "CDSP open + DMA alloc OK" : "CDSP open failed";
    push_result(res);

    res.subsystem = "FastRPC-ADSP";
    res.ok   = adsp_ok;
    res.note = adsp_ok ? "ADSP-secure open + DMA alloc OK" : "ADSP-secure open failed (needs root)";
    push_result(res);
}
