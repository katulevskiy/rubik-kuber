#include "dmabuf.hpp"
#include <linux/dma-heap.h>
#include <fcntl.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>
#include <string>
#include <new>

DmaBuf::DmaBuf(size_t size, const char* heap) {
    std::string path = std::string("/dev/dma_heap/") + heap;
    int hfd = ::open(path.c_str(), O_RDWR | O_CLOEXEC);
    if (hfd < 0) return;

    dma_heap_allocation_data req{};
    req.len      = size;
    req.fd_flags = O_RDWR | O_CLOEXEC;

    if (::ioctl(hfd, DMA_HEAP_IOCTL_ALLOC, &req) == 0) {
        fd_   = req.fd;
        size_ = size;
    }
    ::close(hfd);
}

DmaBuf::~DmaBuf() {
    if (map_) ::munmap(map_, size_);
    if (fd_ >= 0) ::close(fd_);
}

DmaBuf::DmaBuf(DmaBuf&& o) noexcept
    : fd_(o.fd_), size_(o.size_), map_(o.map_) {
    o.fd_ = -1; o.size_ = 0; o.map_ = nullptr;
}

DmaBuf& DmaBuf::operator=(DmaBuf&& o) noexcept {
    if (this != &o) {
        this->~DmaBuf();
        new (this) DmaBuf(std::move(o));
    }
    return *this;
}

void* DmaBuf::ptr() {
    if (!valid()) return nullptr;
    if (!map_) {
        void* p = ::mmap(nullptr, size_, PROT_READ | PROT_WRITE, MAP_SHARED, fd_, 0);
        if (p != MAP_FAILED) map_ = p;
    }
    return map_;
}

const void* DmaBuf::ptr() const {
    return const_cast<DmaBuf*>(this)->ptr();
}
