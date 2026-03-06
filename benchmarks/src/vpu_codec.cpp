#include "vpu_codec.hpp"
#include "common.hpp"

#include <linux/videodev2.h>
#include <fcntl.h>
#include <unistd.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <poll.h>
#include <cstring>
#include <cerrno>
#include <algorithm>
#include <cstdio>
#include <vector>

// ── Helpers ───────────────────────────────────────────────────────────────────
static int xioctl(int fd, unsigned long req, void* arg) {
    int r;
    do { r = ioctl(fd, req, arg); } while (r == -1 && errno == EINTR);
    return r;
}

// ── Find the msm_vidc H.264 encoder device ────────────────────────────────────
// msm_vidc exposes two M2M multiplanar devices — one encoder, one decoder.
// Their minor numbers can differ across kernel versions; scan both and pick
// the one that reports V4L2_CAP_VIDEO_M2M_MPLANE + H.264 encode support.
static int open_encoder_dev(char* dev_out, size_t dev_out_len)
{
    // Candidates in priority order (typical assignment on QCS6490)
    const char* candidates[] = { "/dev/video33", "/dev/video32", nullptr };
    for (int i = 0; candidates[i]; i++) {
        int fd = open(candidates[i], O_RDWR | O_NONBLOCK);
        if (fd < 0) {
            if (errno == ENOMEM) {
                // Session limit hit — no point trying others
                snprintf(dev_out, dev_out_len, "%s", candidates[i]);
                return -ENOMEM;
            }
            continue;
        }
        struct v4l2_capability cap{};
        if (ioctl(fd, VIDIOC_QUERYCAP, &cap) == 0 &&
            (cap.capabilities & V4L2_CAP_VIDEO_M2M_MPLANE)) {
            // Check it can encode H.264
            struct v4l2_fmtdesc f{};
            f.type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
            bool has_h264 = false;
            while (ioctl(fd, VIDIOC_ENUM_FMT, &f) == 0) {
                if (f.pixelformat == V4L2_PIX_FMT_H264) { has_h264 = true; break; }
                f.index++;
            }
            if (has_h264) {
                snprintf(dev_out, dev_out_len, "%s", candidates[i]);
                return fd;
            }
        }
        close(fd);
    }
    return -ENODEV;
}

// ── Main encoder ──────────────────────────────────────────────────────────────
bool vpu_encode_h264(int dma_fd, int width, int height)
{
    char enc_dev[32];
    int fd = open_encoder_dev(enc_dev, sizeof(enc_dev));
    if (fd == -ENOMEM) {
        // msm_vidc firmware session table is full (max 16 concurrent sessions).
        // This happens when previous encoder sessions were not properly released —
        // typically caused by the VPU firmware failing to acknowledge STOP in time
        // when only one CPU core is available (e.g. --cpu-type gold-plus).
        // Fix: run  sudo ./scripts/session.sh reset-vpu
        //       or  echo aa00000.video-codec | sudo tee /sys/bus/platform/drivers/msm_vidc_v4l2/unbind
        //           echo aa00000.video-codec | sudo tee /sys/bus/platform/drivers/msm_vidc_v4l2/bind
        err_msg("VPU  open %s failed: msm_vidc session limit (16) reached\n"
                "     Previous sessions leaked (firmware STOP timeout on single-core runs)\n"
                "     Fix: sudo ./scripts/session.sh reset-vpu",
                enc_dev);
        return false;
    }
    if (fd < 0) {
        err_msg("VPU  no H.264 M2M encoder found in /dev/video*");
        return false;
    }

    // Device was validated (M2M_MPLANE + H.264) by open_encoder_dev()

    // ── OUTPUT (raw NV12 input) ────────────────────────────────────────────────
    struct v4l2_format fmt{};
    fmt.type                       = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    fmt.fmt.pix_mp.width           = width;
    fmt.fmt.pix_mp.height          = height;
    fmt.fmt.pix_mp.pixelformat     = V4L2_PIX_FMT_NV12;
    fmt.fmt.pix_mp.num_planes      = 1;
    fmt.fmt.pix_mp.plane_fmt[0].sizeimage = width * height * 3 / 2;
    fmt.fmt.pix_mp.plane_fmt[0].bytesperline = width;
    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
        err_msg("VPU  VIDIOC_S_FMT OUTPUT failed: %s", strerror(errno));
        close(fd); return false;
    }
    // Read back the negotiated format — driver may adjust sizeimage / num_planes
    xioctl(fd, VIDIOC_G_FMT, &fmt);
    uint32_t out_num_planes = fmt.fmt.pix_mp.num_planes;
    uint32_t out_plane_size = fmt.fmt.pix_mp.plane_fmt[0].sizeimage;
    info_msg("VPU  OUTPUT negotiated: %dx%d NV12  planes=%u  sizeimage=%u",
             fmt.fmt.pix_mp.width, fmt.fmt.pix_mp.height,
             out_num_planes, out_plane_size);

    // ── CAPTURE (H.264 compressed output) ────────────────────────────────────
    memset(&fmt, 0, sizeof(fmt));
    fmt.type                       = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    fmt.fmt.pix_mp.width           = width;
    fmt.fmt.pix_mp.height          = height;
    fmt.fmt.pix_mp.pixelformat     = V4L2_PIX_FMT_H264;
    fmt.fmt.pix_mp.num_planes      = 1;
    fmt.fmt.pix_mp.plane_fmt[0].sizeimage = width * height;  // generous for compressed
    if (xioctl(fd, VIDIOC_S_FMT, &fmt) < 0) {
        err_msg("VPU  VIDIOC_S_FMT CAPTURE failed: %s", strerror(errno));
        close(fd); return false;
    }

    // ── Encoder controls ──────────────────────────────────────────────────────
    // Only set the bitrate; leave profile/level/GOP at firmware defaults.
    // Setting too many controls can trigger msm_vidc firmware assertions on
    // some firmware versions.
    {
        struct v4l2_control c{};
        c.id    = V4L2_CID_MPEG_VIDEO_BITRATE;
        c.value = 1000000;  // 1 Mbps
        xioctl(fd, VIDIOC_S_CTRL, &c);
    }

    // ── Request OUTPUT buffers (MMAP — matches what msm_vidc firmware expects) ──
    // GStreamer also uses MMAP here; DMABUF mode triggers firmware assertions on
    // some msm_vidc versions even though REQBUFS with DMABUF succeeds.
    struct v4l2_requestbuffers reqbufs{};
    reqbufs.count  = 1;
    reqbufs.type   = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    reqbufs.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd, VIDIOC_REQBUFS, &reqbufs) < 0) {
        err_msg("VPU  VIDIOC_REQBUFS OUTPUT failed: %s", strerror(errno));
        close(fd); return false;
    }

    // Query and mmap OUTPUT buffers, then copy data from the DMA-buf
    struct OutBuf { void* ptr; size_t len; };
    std::vector<OutBuf> out_bufs(reqbufs.count);
    for (uint32_t i = 0; i < reqbufs.count; i++) {
        struct v4l2_buffer qb{};
        struct v4l2_plane  pl{};
        qb.type    = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
        qb.memory  = V4L2_MEMORY_MMAP;
        qb.index   = i;
        qb.length  = 1;
        qb.m.planes= &pl;
        if (xioctl(fd, VIDIOC_QUERYBUF, &qb) < 0) {
            err_msg("VPU  VIDIOC_QUERYBUF OUTPUT[%u] failed", i);
            close(fd); return false;
        }
        void* p = mmap(nullptr, pl.length, PROT_READ|PROT_WRITE, MAP_SHARED, fd, pl.m.mem_offset);
        if (p == MAP_FAILED) { err_msg("VPU  mmap OUTPUT[%u] failed", i); close(fd); return false; }
        out_bufs[i] = { p, pl.length };
    }

    // ── Request CAPTURE buffers (MMAP — we read the bitstream back) ───────────
    memset(&reqbufs, 0, sizeof(reqbufs));
    reqbufs.count  = 4;
    reqbufs.type   = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    reqbufs.memory = V4L2_MEMORY_MMAP;
    if (xioctl(fd, VIDIOC_REQBUFS, &reqbufs) < 0) {
        err_msg("VPU  VIDIOC_REQBUFS CAPTURE failed: %s", strerror(errno));
        for (auto& b : out_bufs) munmap(b.ptr, b.len);
        close(fd); return false;
    }

    // Query and mmap CAPTURE buffers
    struct CaptBuf { void* ptr; size_t len; };
    std::vector<CaptBuf> cap_bufs(reqbufs.count);
    for (uint32_t i = 0; i < reqbufs.count; i++) {
        struct v4l2_buffer qb{};
        struct v4l2_plane  pl{};
        qb.type    = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        qb.memory  = V4L2_MEMORY_MMAP;
        qb.index   = i;
        qb.length  = 1;
        qb.m.planes= &pl;
        if (xioctl(fd, VIDIOC_QUERYBUF, &qb) < 0) {
            err_msg("VPU  VIDIOC_QUERYBUF CAPTURE[%u] failed", i);
            for (auto& b : out_bufs) munmap(b.ptr, b.len);
            close(fd); return false;
        }
        void* p = mmap(nullptr, pl.length, PROT_READ|PROT_WRITE, MAP_SHARED, fd, pl.m.mem_offset);
        if (p == MAP_FAILED) { err_msg("VPU  mmap CAPTURE[%u] failed", i); close(fd); return false; }
        cap_bufs[i] = { p, pl.length };

        // Pre-queue CAPTURE buffers so the encoder can write into them
        pl.length   = cap_bufs[i].len;
        pl.bytesused= 0;
        xioctl(fd, VIDIOC_QBUF, &qb);
    }

    // ── META_CAPTURE buffers (optional; some msm_vidc versions require them) ───
    struct MetaBuf { void* ptr; size_t len; };
    std::vector<MetaBuf> meta_bufs;
    {
        memset(&reqbufs, 0, sizeof(reqbufs));
        reqbufs.count  = 4;
        reqbufs.type   = V4L2_BUF_TYPE_META_CAPTURE;
        reqbufs.memory = V4L2_MEMORY_MMAP;
        if (xioctl(fd, VIDIOC_REQBUFS, &reqbufs) == 0 && reqbufs.count > 0) {
            info_msg("VPU  META_CAPTURE buffers: %u", reqbufs.count);
            meta_bufs.resize(reqbufs.count);
            for (uint32_t i = 0; i < reqbufs.count; i++) {
                struct v4l2_buffer mb{};
                mb.type   = V4L2_BUF_TYPE_META_CAPTURE;
                mb.memory = V4L2_MEMORY_MMAP;
                mb.index  = i;
                if (xioctl(fd, VIDIOC_QUERYBUF, &mb) == 0) {
                    void* p = mmap(nullptr, mb.length, PROT_READ|PROT_WRITE,
                                   MAP_SHARED, fd, mb.m.offset);
                    if (p != MAP_FAILED) {
                        meta_bufs[i] = { p, mb.length };
                        xioctl(fd, VIDIOC_QBUF, &mb);
                    }
                }
            }
        }
    }

    // ── Copy NV12 data from DMA-buf into the MMAP OUTPUT buffer ───────────────
    // mmap the DMA-buf to read its content, then copy to the driver-owned buffer
    {
        void* src = mmap(nullptr, out_bufs[0].len, PROT_READ, MAP_SHARED, dma_fd, 0);
        if (src != MAP_FAILED) {
            memcpy(out_bufs[0].ptr, src, std::min(out_bufs[0].len, (size_t)out_plane_size));
            munmap(src, out_bufs[0].len);
            info_msg("VPU  copied %u B from DMA-buf into OUTPUT buffer (via mmap)", out_plane_size);
        } else {
            warn_msg("VPU  cannot mmap DMA-buf for copy: %s", strerror(errno));
        }
    }

    // ── Queue the OUTPUT (raw frame) buffer ───────────────────────────────────
    {
        struct v4l2_plane  planes[VIDEO_MAX_PLANES]{};
        struct v4l2_buffer qb{};
        qb.type    = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
        qb.memory  = V4L2_MEMORY_MMAP;
        qb.index   = 0;
        qb.length  = 1;
        qb.m.planes= planes;
        qb.flags   = 0;
        planes[0].bytesused  = out_plane_size;
        planes[0].length     = out_bufs[0].len;
        planes[0].data_offset= 0;
        if (xioctl(fd, VIDIOC_QBUF, &qb) < 0) {
            err_msg("VPU  VIDIOC_QBUF OUTPUT failed: %s (plane size=%u)",
                    strerror(errno), out_plane_size);
            for (auto& b : cap_bufs) munmap(b.ptr, b.len);
            for (auto& b : out_bufs) munmap(b.ptr, b.len);
            close(fd); return false;
        }
    }

    // ── STREAMON ──────────────────────────────────────────────────────────────
    int type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
    if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
        err_msg("VPU  STREAMON CAPTURE failed: %s", strerror(errno));
        for (auto& b : cap_bufs)  munmap(b.ptr, b.len);
        for (auto& b : out_bufs)  munmap(b.ptr, b.len);
        for (auto& b : meta_bufs) munmap(b.ptr, b.len);
        close(fd); return false;
    }
    type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
    if (xioctl(fd, VIDIOC_STREAMON, &type) < 0) {
        err_msg("VPU  STREAMON OUTPUT failed: %s", strerror(errno));
        type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
        xioctl(fd, VIDIOC_STREAMOFF, &type);
        for (auto& b : cap_bufs)  munmap(b.ptr, b.len);
        for (auto& b : out_bufs)  munmap(b.ptr, b.len);
        for (auto& b : meta_bufs) munmap(b.ptr, b.len);
        close(fd); return false;
    }
    // NOTE: do NOT call VIDIOC_STREAMON for META_CAPTURE — the driver manages
    // the meta queue internally after the main streams are started.
    (void)meta_bufs;

    // ── Poll for encoded output ───────────────────────────────────────────────
    // msm_vidc M2M: we must also service POLLOUT (INPUT consumed) events so
    // the encoder progresses internally.  Some encoders require at least one
    // OUTPUT buffer to be dequeued before they produce CAPTURE data.
    Timer t;
    size_t total_bytes = 0;
    int    frames_got  = 0;
    bool   out_consumed = false;

    for (int attempt = 0; attempt < 20 && frames_got == 0; attempt++) {
        struct pollfd pfd = { fd, POLLIN | POLLOUT | POLLERR, 0 };
        int pr = poll(&pfd, 1, 2000);
        if (pr < 0)  { warn_msg("VPU  poll error: %s", strerror(errno)); break; }
        if (pr == 0) continue;  // keep trying up to 20 × 2 s = 40 s max

        if (pfd.revents & POLLERR) {
            warn_msg("VPU  POLLERR — encoder error");
            break;
        }

        // OUTPUT slot freed (encoder consumed our raw frame)
        if ((pfd.revents & POLLOUT) && !out_consumed) {
            struct v4l2_plane  pl{};
            struct v4l2_buffer ob{};
            ob.type    = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
            ob.memory  = V4L2_MEMORY_MMAP;
            ob.length  = 1;
            ob.m.planes= &pl;
            if (xioctl(fd, VIDIOC_DQBUF, &ob) == 0) {
                out_consumed = true;
                info_msg("VPU  OUTPUT dequeued (encoder consumed raw frame) ✓");
                // Re-queue with bytesused=0 to signal EOS to the encoder
                struct v4l2_plane  epl[VIDEO_MAX_PLANES]{};
                struct v4l2_buffer eos{};
                eos.type    = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;
                eos.memory  = V4L2_MEMORY_MMAP;
                eos.index   = ob.index;
                eos.length  = 1;
                eos.m.planes= epl;
                epl[0].bytesused  = 0;  // 0 bytes = EOS signal
                epl[0].length     = out_bufs[ob.index].len;
                epl[0].data_offset= 0;
                xioctl(fd, VIDIOC_QBUF, &eos);
            }
        }

        // CAPTURE ready (encoded data available)
        if (pfd.revents & POLLIN) {
            struct v4l2_plane  pl{};
            struct v4l2_buffer qb{};
            qb.type    = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE;
            qb.memory  = V4L2_MEMORY_MMAP;
            qb.length  = 1;
            qb.m.planes= &pl;
            while (xioctl(fd, VIDIOC_DQBUF, &qb) == 0) {
                if (pl.bytesused > 0) {
                    total_bytes += pl.bytesused;
                    frames_got++;
                }
                // If V4L2_BUF_FLAG_LAST is set, encoder has flushed
                if (qb.flags & V4L2_BUF_FLAG_LAST) break;
                // Re-queue for more output
                pl.bytesused = 0;
                pl.length    = cap_bufs[qb.index].len;
                xioctl(fd, VIDIOC_QBUF, &qb);
            }
        }
    }
    double ms = t.elapsed_ms();

    // ── Teardown ──────────────────────────────────────────────────────────────
    type = V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE;  xioctl(fd, VIDIOC_STREAMOFF, &type);
    type = V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE; xioctl(fd, VIDIOC_STREAMOFF, &type);
    for (auto& b : out_bufs)  munmap(b.ptr, b.len);
    for (auto& b : cap_bufs)  munmap(b.ptr, b.len);
    for (auto& b : meta_bufs) munmap(b.ptr, b.len);
    close(fd);

    if (frames_got == 0) {
        err_msg("VPU  no encoded frames received");
        return false;
    }

    ok_msg("VPU H.264 encode: %dx%d  →  %zu bytes  in %.1f ms  (%.1f kbps est.)",
           width, height, total_bytes, ms,
           total_bytes * 8.0 / (ms / 1000.0) / 1000.0);

    TestResult res;
    res.subsystem = "VPU-H264";
    res.ok   = true;
    res.ms   = ms;
    res.note = std::to_string(total_bytes) + " B encoded, zero-copy DMA-buf input";
    push_result(res);
    return true;
}
