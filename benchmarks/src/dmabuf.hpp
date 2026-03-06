#pragma once
#include <cstddef>

// RAII wrapper around a DMA-heap allocated buffer.
// The "system" heap produces cache-coherent buffers accessible by
// CPU, GPU (Adreno), and VPU (msm_vidc) without explicit cache ops.
class DmaBuf {
public:
    DmaBuf() = default;
    explicit DmaBuf(size_t size, const char* heap = "system");
    ~DmaBuf();

    DmaBuf(const DmaBuf&)            = delete;
    DmaBuf& operator=(const DmaBuf&) = delete;
    DmaBuf(DmaBuf&& o) noexcept;
    DmaBuf& operator=(DmaBuf&& o) noexcept;

    bool    valid() const { return fd_ >= 0; }
    int     fd()    const { return fd_; }
    size_t  size()  const { return size_; }

    // Lazy mmap — returns the same pointer on subsequent calls.
    void*       ptr();
    const void* ptr() const;

private:
    int    fd_   = -1;
    size_t size_ = 0;
    void*  map_  = nullptr;
};
