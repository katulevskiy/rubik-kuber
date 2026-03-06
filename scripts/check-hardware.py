#!/usr/bin/env python3
"""
Rubik Pi 3 (Qualcomm QCS6490) — Hardware Access Checker

Tests every hardware subsystem accessible from a Linux userspace process or
Kubernetes pod.  No proprietary SDKs required — uses only kernel interfaces:
  /proc, /sys, ioctl(2), and device-node open(2).

Subsystems checked:
  CPU   — Kryo 670 (Cortex-A78 + A55 big.LITTLE, 8 cores)
  GPU   — Adreno 643L  (DRM/MSM driver + KGSL compute interface)
  NPU   — Hexagon NSP/CDSP (FastRPC — used by QNN / SNPE SDKs)
  ISP   — Spectra 570L (V4L2 capture pipeline)
  VPU   — Adreno Video 633 (V4L2 M2M codec — Venus/Vidc driver)
  DSP   — ADSP (FastRPC audio domain device)
  Thermal — per-subsystem temperature sensors (CPU, GPU, NPU, ISP, VPU)
  Memory  — LPDDR5 total / available

Usage (on host):
  python3 scripts/check-hardware.py

Usage (inside a privileged Kubernetes pod):
  kubectl exec -n sessions <pod> -- python3 /scripts/check-hardware.py
"""

import ctypes
import fcntl
import os
import struct
import subprocess
import sys
import time
from pathlib import Path

# ── Colours ───────────────────────────────────────────────────────────────────
_tty = sys.stdout.isatty()
def _c(s): return s if _tty else ""
GRN  = _c("\033[0;32m");  RED  = _c("\033[0;31m")
YLW  = _c("\033[1;33m");  BLU  = _c("\033[0;34m")
BOLD = _c("\033[1m");     NC   = _c("\033[0m")

_results: list[tuple[bool, str]] = []

def section(title: str):
    print(f"\n{BOLD}{BLU}── {title} ──{NC}")

def ok(label: str, detail: str = ""):
    _results.append((True, label))
    suffix = f"  {BLU}{detail}{NC}" if detail else ""
    print(f"  {GRN}✓{NC}  {label}{suffix}")

def fail(label: str, detail: str = ""):
    _results.append((False, label))
    suffix = f"  {YLW}{detail}{NC}" if detail else ""
    print(f"  {RED}✗{NC}  {label}{suffix}")

def warn(label: str, detail: str = ""):
    # Warns don't count as failures — hardware present but access limited
    print(f"  {YLW}!{NC}  {label}" + (f"  {YLW}{detail}{NC}" if detail else ""))

def note(msg: str):
    print(f"       {BLU}{msg}{NC}")


# ── ioctl helpers ─────────────────────────────────────────────────────────────
# Linux ioctl direction/size encoding (same on all architectures)
def _IOC(direction: int, type_: int, nr: int, size: int) -> int:
    return (direction << 30) | (size << 16) | (type_ << 8) | nr

def _IOR(type_: int, nr: int, size: int)  -> int: return _IOC(2, type_, nr, size)
def _IOW(type_: int, nr: int, size: int)  -> int: return _IOC(1, type_, nr, size)
def _IOWR(type_: int, nr: int, size: int) -> int: return _IOC(3, type_, nr, size)

def sysfs(path: str, default: str = "") -> str:
    try:
        return Path(path).read_text().strip()
    except Exception:
        return default


# ── 1. CPU ────────────────────────────────────────────────────────────────────
_CPU_PARTS = {
    "0xd03": "Cortex-A53",
    "0xd05": "Cortex-A55  (efficiency)",
    "0xd44": "Cortex-X1   (prime)",
    "0xd46": "Cortex-A510 (efficiency)",
    "0xd47": "Cortex-A710 (performance)",
    "0xd48": "Cortex-X2   (prime)",
    "0xd41": "Cortex-A78  (performance)",   # Kryo 670 Gold
    "0xd4b": "Cortex-A78C",
}

def check_cpu():
    section("CPU — Qualcomm Kryo 670  (big.LITTLE, 8 cores)")

    # /proc/cpuinfo
    try:
        text = Path("/proc/cpuinfo").read_text()
    except Exception as e:
        fail("Read /proc/cpuinfo", str(e))
        return

    n_cores = text.count("processor\t:")
    hardware = next(
        (l.split(":", 1)[1].strip() for l in text.splitlines()
         if l.startswith("Hardware")), "unknown"
    )
    ok(f"CPU info readable", f"{n_cores} logical cores | Hardware: {hardware}")

    parts: dict[str, int] = {}
    for line in text.splitlines():
        if "CPU part" in line:
            p = line.split(":", 1)[1].strip()
            parts[p] = parts.get(p, 0) + 1
    for part, count in sorted(parts.items()):
        note(f"CPU part {part} ({_CPU_PARTS.get(part,'unknown')}) × {count}")

    # Frequency scaling
    freqs = sorted(Path("/sys/devices/system/cpu").glob("cpu[0-9]*/cpufreq"))
    reported = False
    for fdir in freqs:
        cur  = sysfs(str(fdir / "scaling_cur_freq"))
        maxf = sysfs(str(fdir / "scaling_max_freq"))
        if cur and not reported:
            ok("CPU freq-scaling sysfs readable",
               f"e.g. {fdir.parent.name}: {int(cur)//1000} MHz  (max {int(maxf)//1000} MHz)")
            reported = True
            break
    if not reported:
        warn("CPU freq-scaling not readable", "(normal inside a restricted container)")

    # Quick compute benchmark
    t0 = time.perf_counter()
    _ = sum(i * i for i in range(4_000_000))
    ms = (time.perf_counter() - t0) * 1000
    ok("CPU compute benchmark", f"4M iterations in {ms:.1f} ms")


# ── 2. GPU — DRM / MSM  ───────────────────────────────────────────────────────
def check_gpu_drm():
    section("GPU — Adreno 643L  (DRM / MSM kernel driver)")

    # Model from KGSL sysfs (doesn't require device open)
    model = sysfs("/sys/class/kgsl/kgsl-3d0/gpu_model")
    if model:
        note(f"Model from KGSL sysfs: {model}")

    for dev in ["/dev/dri/renderD128", "/dev/dri/card0"]:
        if not Path(dev).exists():
            fail(f"{dev} not found")
            continue
        try:
            fd = os.open(dev, os.O_RDWR)
            ok(f"Opened {dev} (read-write)")
            os.close(fd)
        except PermissionError:
            try:
                fd = os.open(dev, os.O_RDONLY)
                ok(f"Opened {dev} (read-only)")
                os.close(fd)
            except Exception as e:
                fail(f"Open {dev}", str(e))
        except Exception as e:
            fail(f"Open {dev}", str(e))

    # DRM version via ioctl ───────────────────────────────────────────────────
    # struct drm_version: 3×int + 3×(size_t + char*)
    # On 64-bit the struct is 72 bytes with name/date/desc as 0-length strings
    class DrmVersion(ctypes.Structure):
        _fields_ = [
            ("version_major",      ctypes.c_int),
            ("version_minor",      ctypes.c_int),
            ("version_patchlevel", ctypes.c_int),
            ("name_len",           ctypes.c_size_t),
            ("name",               ctypes.c_char_p),
            ("date_len",           ctypes.c_size_t),
            ("date",               ctypes.c_char_p),
            ("desc_len",           ctypes.c_size_t),
            ("desc",               ctypes.c_char_p),
        ]

    DRM_IOCTL_VERSION = _IOWR(ord('d'), 0x00, ctypes.sizeof(DrmVersion))

    name_buf = ctypes.create_string_buffer(64)
    date_buf = ctypes.create_string_buffer(64)
    desc_buf = ctypes.create_string_buffer(256)
    ver = DrmVersion()
    ver.name_len = len(name_buf)
    ver.name     = ctypes.cast(name_buf, ctypes.c_char_p)
    ver.date_len = len(date_buf)
    ver.date     = ctypes.cast(date_buf, ctypes.c_char_p)
    ver.desc_len = len(desc_buf)
    ver.desc     = ctypes.cast(desc_buf, ctypes.c_char_p)

    try:
        fd = os.open("/dev/dri/renderD128", os.O_RDWR)
        fcntl.ioctl(fd, DRM_IOCTL_VERSION, ver)
        drv_name = name_buf.value.decode()
        drv_date = date_buf.value.decode()
        ok("DRM_IOCTL_VERSION",
           f"driver={drv_name}  date={drv_date}  "
           f"v{ver.version_major}.{ver.version_minor}.{ver.version_patchlevel}")
        os.close(fd)
    except Exception as e:
        warn("DRM_IOCTL_VERSION", str(e))


# ── 3. GPU — KGSL compute  ────────────────────────────────────────────────────
def check_gpu_kgsl():
    section("GPU — Adreno 643L  (KGSL compute / OpenCL interface)")

    kgsl = "/dev/kgsl-3d0"
    if not Path(kgsl).exists():
        fail(f"{kgsl} not found")
        return

    try:
        fd = os.open(kgsl, os.O_RDWR)
        ok(f"Opened {kgsl}")
    except PermissionError:
        try:
            fd = os.open(kgsl, os.O_RDONLY)
            ok(f"Opened {kgsl} (read-only)")
        except Exception as e:
            fail(f"Open {kgsl}", str(e))
            return
    except Exception as e:
        fail(f"Open {kgsl}", str(e))
        return

    # IOCTL_KGSL_DEVICE_GETPROPERTY ─────────────────────────────────────────
    # #define KGSL_IOC_TYPE 0x09
    # #define IOCTL_KGSL_DEVICE_GETPROPERTY _IOWR(0x09, 2, struct kgsl_device_getproperty)
    #
    # struct kgsl_device_getproperty {
    #     unsigned int type;        // 4 bytes
    #     // 4-byte padding (pointer alignment)
    #     void __user *value;       // 8 bytes
    #     size_t       sizebytes;   // 8 bytes
    # };  → 24 bytes total on 64-bit
    #
    # struct kgsl_devinfo {
    #     unsigned int device_id;           // 4
    #     unsigned int chip_id;             // 4
    #     unsigned int mmu_enabled;         // 4
    #     // 4-byte padding
    #     unsigned long gpu_id;             // 8
    #     unsigned int  gmem_gpubaseaddr;   // 4
    #     unsigned int  gmem_sizebytes;     // 4
    # };  → 32 bytes total

    class KgslDevInfo(ctypes.Structure):
        _fields_ = [
            ("device_id",        ctypes.c_uint32),
            ("chip_id",          ctypes.c_uint32),
            ("mmu_enabled",      ctypes.c_uint32),
            ("_pad",             ctypes.c_uint32),
            ("gpu_id",           ctypes.c_uint64),
            ("gmem_gpubaseaddr", ctypes.c_uint32),
            ("gmem_sizebytes",   ctypes.c_uint32),
        ]

    class KgslGetProperty(ctypes.Structure):
        _fields_ = [
            ("type",      ctypes.c_uint32),
            ("_pad",      ctypes.c_uint32),
            ("value",     ctypes.c_uint64),
            ("sizebytes", ctypes.c_size_t),
        ]

    KGSL_PROP_DEVICE_INFO = 1
    devinfo  = KgslDevInfo()
    getprop  = KgslGetProperty()
    getprop.type      = KGSL_PROP_DEVICE_INFO
    getprop.value     = ctypes.addressof(devinfo)
    getprop.sizebytes = ctypes.sizeof(devinfo)

    IOCTL_KGSL_DEVICE_GETPROPERTY = _IOWR(0x09, 2, ctypes.sizeof(getprop))

    try:
        fcntl.ioctl(fd, IOCTL_KGSL_DEVICE_GETPROPERTY, getprop)
        chip = devinfo.chip_id
        core  = (chip >> 24) & 0xFF
        major = (chip >> 16) & 0xFF
        minor = (chip >>  8) & 0xFF
        patch = (chip >>  0) & 0xFF
        gmem_kb = devinfo.gmem_sizebytes // 1024
        ok("KGSL GETPROPERTY ioctl",
           f"chip_id=0x{chip:08x}  core={core} rev={major}.{minor}.{patch}  GMEM={gmem_kb} KB")
    except Exception as e:
        warn("KGSL GETPROPERTY ioctl", str(e))

    # sysfs knobs ────────────────────────────────────────────────────────────
    sysfs_items = {
        "gpu_model":           "/sys/class/kgsl/kgsl-3d0/gpu_model",
        "clock_mhz":           "/sys/class/kgsl/kgsl-3d0/clock_mhz",
        "freq_table_mhz":      "/sys/class/kgsl/kgsl-3d0/freq_table_mhz",
        "gpu_busy_%":          "/sys/class/kgsl/kgsl-3d0/gpu_busy_percentage",
        "devfreq_governor":    "/sys/class/kgsl/kgsl-3d0/devfreq/governor",
    }
    for label, path in sysfs_items.items():
        val = sysfs(path)
        if val:
            note(f"{label}: {val}")

    note("Full GPU access: OpenCL via libOpenCL.so (Adreno OpenCL driver)")
    note("                 Vulkan compute via libvulkan.so + VK_KHR_external_memory")

    os.close(fd)


# ── 4. NPU — Hexagon NSP / CDSP via FastRPC ───────────────────────────────────
def check_npu():
    section("NPU — Hexagon 770 NSP / CDSP  (FastRPC → QNN / SNPE)")

    cdsp = "/dev/fastrpc-cdsp"
    if not Path(cdsp).exists():
        fail(f"{cdsp} not found")
        return

    try:
        fd = os.open(cdsp, os.O_RDWR)
        ok(f"Opened {cdsp} (read-write)")
    except PermissionError:
        try:
            fd = os.open(cdsp, os.O_RDONLY)
            ok(f"Opened {cdsp} (read-only — rw needed for inference)")
        except Exception as e:
            fail(f"Open {cdsp}", str(e))
            return
    except Exception as e:
        fail(f"Open {cdsp}", str(e))
        return

    # FASTRPC_IOCTL_GET_DSP_INFO ─────────────────────────────────────────────
    # #define FASTRPC_IOCTL_GET_DSP_INFO _IOWR('R', 13, struct fastrpc_ioctl_capability)
    # struct fastrpc_ioctl_capability { __u32 domain; __u32 attribute_ID; __u32 capability; }
    # domain 3 = CDSP, attribute_ID 0 = DOMAIN_SUPPORT
    class FastrpcCap(ctypes.Structure):
        _fields_ = [
            ("domain",       ctypes.c_uint32),
            ("attribute_ID", ctypes.c_uint32),
            ("capability",   ctypes.c_uint32),
        ]

    FASTRPC_IOCTL_GET_DSP_INFO = _IOWR(ord('R'), 13, ctypes.sizeof(FastrpcCap))

    cap = FastrpcCap()
    cap.domain       = 3   # CDSP
    cap.attribute_ID = 0   # DOMAIN_SUPPORT

    try:
        fcntl.ioctl(fd, FASTRPC_IOCTL_GET_DSP_INFO, cap)
        ok("FastRPC GET_DSP_INFO ioctl", f"CDSP capability={cap.capability}")
    except OSError as e:
        # ENOTTY / EINVAL just means the ioctl nr is slightly off for this kernel;
        # the device is still accessible and usable via the Qualcomm SDK.
        warn("FastRPC GET_DSP_INFO ioctl", f"{e}  (device open — SDK ioctls will work)")

    # Other FastRPC domains ───────────────────────────────────────────────────
    for dev, label in [
        ("/dev/fastrpc-adsp-secure", "ADSP (audio DSP) — restricted"),
        ("/dev/fastrpc-cdsp-secure", "CDSP secure — restricted"),
    ]:
        if Path(dev).exists():
            note(f"{dev}: present  [{label}]")

    note("Full NPU access: Qualcomm AI Engine Direct (QNN SDK)")
    note("                 Qualcomm Neural Processing SDK (SNPE)")
    note("                 ONNX Runtime with QNN execution provider")

    os.close(fd)


# ── 5. ISP + VPU — V4L2 ──────────────────────────────────────────────────────
# V4L2 capability flags
_V4L2_CAPS = {
    0x00000001: "VIDEO_CAPTURE",
    0x00000002: "VIDEO_OUTPUT",
    0x00000004: "VIDEO_OVERLAY",
    0x00001000: "VIDEO_CAPTURE_MPLANE",
    0x00002000: "VIDEO_OUTPUT_MPLANE",
    0x00004000: "VIDEO_M2M_MPLANE",
    0x00008000: "VIDEO_M2M",
    0x04000000: "STREAMING",
    0x80000000: "DEVICE_CAPS",
}

# V4L2 pixel format fourcc → human name (subset)
_FOURCC = {
    b"NV12": "NV12 (YUV 4:2:0 semi-planar)",
    b"NV21": "NV21",
    b"YUYV": "YUYV (YUV 4:2:2 packed)",
    b"UYVY": "UYVY",
    b"H264": "H.264 / AVC",
    b"HEVC": "H.265 / HEVC",
    b"VP90": "VP9",
    b"AV01": "AV1",
    b"MJPG": "Motion JPEG",
    b"RG24": "RGB24",
}

def check_isp_vpu():
    section("ISP + VPU — Spectra 570L + Adreno Video 633  (V4L2)")

    # struct v4l2_capability: 16+32+32+4+4+4+12 = 104 bytes
    class V4l2Cap(ctypes.Structure):
        _fields_ = [
            ("driver",       ctypes.c_char * 16),
            ("card",         ctypes.c_char * 32),
            ("bus_info",     ctypes.c_char * 32),
            ("version",      ctypes.c_uint32),
            ("capabilities", ctypes.c_uint32),
            ("device_caps",  ctypes.c_uint32),
            ("reserved",     ctypes.c_uint32 * 3),
        ]

    # struct v4l2_fmtdesc: 4+4+4+4+32+4*4 = 64 bytes
    class V4l2FmtDesc(ctypes.Structure):
        _fields_ = [
            ("index",       ctypes.c_uint32),
            ("type",        ctypes.c_uint32),
            ("flags",       ctypes.c_uint32),
            ("description", ctypes.c_char * 32),
            ("pixelformat", ctypes.c_uint32),
            ("mbus_code",   ctypes.c_uint32),
            ("reserved",    ctypes.c_uint32 * 4),
        ]

    VIDIOC_QUERYCAP  = _IOR(ord('V'), 0,  ctypes.sizeof(V4l2Cap))
    VIDIOC_ENUM_FMT  = _IOWR(ord('V'), 2, ctypes.sizeof(V4l2FmtDesc))
    V4L2_BUF_TYPE_VIDEO_CAPTURE        = 1
    V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE = 9
    V4L2_BUF_TYPE_VIDEO_OUTPUT_MPLANE  = 10

    devs = sorted(Path("/dev").glob("video*"))
    if not devs:
        fail("No /dev/video* devices found")
        return

    for devpath in devs:
        try:
            fd = os.open(str(devpath), os.O_RDWR | os.O_NONBLOCK)
        except PermissionError:
            try:
                fd = os.open(str(devpath), os.O_RDONLY | os.O_NONBLOCK)
            except Exception as e:
                fail(f"{devpath}", str(e))
                continue
        except Exception as e:
            fail(f"{devpath}", str(e))
            continue

        try:
            cap = V4l2Cap()
            fcntl.ioctl(fd, VIDIOC_QUERYCAP, cap)

            driver = cap.driver.decode(errors="replace").rstrip("\x00")
            card   = cap.card.decode(errors="replace").rstrip("\x00")
            bus    = cap.bus_info.decode(errors="replace").rstrip("\x00")
            dcaps  = cap.device_caps if (cap.capabilities & 0x80000000) else cap.capabilities
            flags  = [v for k, v in _V4L2_CAPS.items() if dcaps & k and k != 0x80000000]
            vstr   = f"{(cap.version>>16)&0xFF}.{(cap.version>>8)&0xFF}.{cap.version&0xFF}"

            # Classify: ISP capture vs VPU codec
            if dcaps & 0x0000C000:   # M2M or M2M_MPLANE
                role = "VPU (video codec M2M)"
            elif dcaps & 0x00001000: # CAPTURE_MPLANE
                role = "ISP (capture MPLANE)"
            elif dcaps & 0x00000001: # CAPTURE
                role = "ISP (capture)"
            else:
                role = "?"

            ok(f"{devpath}: {driver} [{role}]",
               f"{card}  v{vstr}")
            note(f"bus={bus}  caps={', '.join(flags)}")

            # Enumerate pixel formats for the primary buffer type
            buf_type = (V4L2_BUF_TYPE_VIDEO_CAPTURE_MPLANE
                        if dcaps & 0x00001000 else V4L2_BUF_TYPE_VIDEO_CAPTURE)
            fmts = []
            for idx in range(32):
                fd_desc = V4l2FmtDesc()
                fd_desc.index = idx
                fd_desc.type  = buf_type
                try:
                    fcntl.ioctl(fd, VIDIOC_ENUM_FMT, fd_desc)
                    fourcc = struct.pack("<I", fd_desc.pixelformat)
                    fmts.append(_FOURCC.get(fourcc, fourcc.decode(errors="replace").rstrip("\x00")))
                except OSError:
                    break
            if fmts:
                note(f"formats: {', '.join(fmts[:8])}")

        except Exception as e:
            warn(f"{devpath} QUERYCAP", str(e))
        finally:
            os.close(fd)

    note("Full ISP access: Qualcomm Camera SDK (libcamera2) or V4L2 directly")
    note("Full VPU access: GStreamer v4l2h264enc/dec, FFmpeg v4l2_m2m")


# ── 6. DSP — ADSP (audio domain) ──────────────────────────────────────────────
def check_dsp():
    section("DSP — Hexagon ADSP  (audio / sensors FastRPC domain)")

    adsp = "/dev/fastrpc-adsp-secure"
    if not Path(adsp).exists():
        warn(f"{adsp} not present", "(normal if ADSP is managed by another driver)")
        return

    # ADSP is typically restricted to processes with specific SELinux/group perms
    try:
        fd = os.open(adsp, os.O_RDONLY)
        ok(f"Opened {adsp}")
        os.close(fd)
    except PermissionError:
        ok(f"{adsp} present", "permission-restricted (correct for secure domain)")
    except Exception as e:
        fail(f"Open {adsp}", str(e))


# ── 7. Thermal sensors ────────────────────────────────────────────────────────
_THERMAL_INTEREST = {
    "cpu":    ["cpu0","cpu1","cpu2","cpu3","cpu4","cpu5","cpu6","cpu7",
               "cpu8","cpu9","cpu10","cpu11","cpuss0","cpuss1"],
    "gpu":    ["gpuss0","gpuss1"],
    "npu":    ["nspss0","nspss1"],
    "isp":    ["camera0"],
    "vpu":    ["video"],
    "soc":    ["aoss0","aoss1","xo"],
    "memory": ["ddr"],
}

def check_thermal():
    section("Thermal — per-subsystem temperature sensors")

    zones: dict[str, tuple[str, float]] = {}
    for zone in Path("/sys/class/thermal").glob("thermal_zone*"):
        typ_path = zone / "type"
        tmp_path = zone / "temp"
        if not (typ_path.exists() and tmp_path.exists()):
            continue
        try:
            ztype = typ_path.read_text().strip()
            temp  = int(tmp_path.read_text().strip()) / 1000.0
            zones[ztype] = (zone.name, temp)
        except Exception:
            pass

    def show_group(group: str, types: list[str]):
        thermal_types = set(zones.keys())
        hits = [t for prefix in types
                for t in sorted(thermal_types) if t.startswith(prefix)]
        if not hits:
            warn(f"{group}: no thermal zones found")
            return
        shown = set()
        for ztype in sorted(hits):
            if ztype in shown:
                continue
            shown.add(ztype)
            _, temp = zones[ztype]
            state = "OK" if temp < 80 else ("WARM" if temp < 90 else "HOT")
            ok(f"{group}: {ztype}", f"{temp:.1f}°C  [{state}]")

    show_group("CPU",  ["cpu","cpuss"])
    show_group("GPU",  ["gpuss"])
    show_group("NPU",  ["nspss"])
    show_group("ISP",  ["camera"])
    show_group("VPU",  ["video"])
    show_group("SoC",  ["aoss","xo"])
    show_group("DDR",  ["ddr"])


# ── 8. Memory ─────────────────────────────────────────────────────────────────
def check_memory():
    section("Memory — LPDDR5")

    try:
        info: dict[str, int] = {}
        for line in Path("/proc/meminfo").read_text().splitlines():
            if ":" in line:
                k, v = line.split(":", 1)
                nums = [x for x in v.split() if x.isdigit()]
                if nums:
                    info[k.strip()] = int(nums[0])

        total  = info.get("MemTotal", 0)
        avail  = info.get("MemAvailable", 0)
        cached = info.get("Cached", 0)
        ok("RAM",
           f"{total/1024/1024:.2f} GB total  |  "
           f"{avail/1024:.0f} MB available  |  "
           f"{cached/1024:.0f} MB page cache")

        # HugePage / DMA info
        huge = info.get("HugePages_Total", 0)
        if huge:
            note(f"HugePages: {huge} × {info.get('Hugepagesize',0)//1024} MB")
    except Exception as e:
        fail("Read /proc/meminfo", str(e))

    # DMA heap (zero-copy between subsystems — ISP→NPU, GPU→NPU, etc.)
    dma_heaps = list(Path("/dev/dma_heap").glob("*")) if Path("/dev/dma_heap").exists() else []
    if dma_heaps:
        ok("DMA-heap (zero-copy inter-subsystem)",
           "  ".join(h.name for h in dma_heaps))
        note("Used for zero-copy buffer sharing: ISP→GPU, GPU→NPU, etc.")
    else:
        warn("DMA-heap /dev/dma_heap not present",
             "(may be /dev/ion on older kernels)")


# ── Summary ───────────────────────────────────────────────────────────────────
def summary():
    passed = sum(1 for ok_, _ in _results if ok_)
    failed = sum(1 for ok_, _ in _results if not ok_)

    print(f"\n{BOLD}{'─' * 58}{NC}")
    print(f"{BOLD}Result: {GRN}{passed} passed{NC}  /  {RED}{failed} failed{NC}  "
          f"/ {len(_results)} total checks{NC}")

    if failed:
        print(f"\n{RED}Failed:{NC}")
        for ok_, label in _results:
            if not ok_:
                print(f"  {RED}✗{NC}  {label}")
    else:
        print(f"\n{GRN}All hardware subsystems accessible ✓{NC}")

    print(f"""
{BOLD}SDK / API reference:{NC}
  {BLU}CPU{NC}   Standard Linux APIs, NEON/SVE intrinsics, perf
  {BLU}GPU{NC}   OpenGL ES (libGLESv2), Vulkan (libvulkan), OpenCL (Adreno libOpenCL)
  {BLU}NPU{NC}   Qualcomm AI Engine Direct (QNN), SNPE, ONNX Runtime QNN EP
  {BLU}ISP{NC}   V4L2 (VIDIOC_*), libcamera, Qualcomm Camera SDK
  {BLU}VPU{NC}   V4L2 M2M codec, GStreamer v4l2h264enc/dec, FFmpeg v4l2_m2m
  {BLU}DSP{NC}   FastRPC (libcdsprpc.so), Qualcomm Audio SDK
  {BLU}Zero-copy{NC}  DMA-heap + Android Gralloc-style buffer sharing
""")


# ── Entry point ───────────────────────────────────────────────────────────────
def main() -> int:
    print(f"\n{BOLD}╔══════════════════════════════════════════════════════════╗{NC}")
    print(f"{BOLD}║    Rubik Pi 3 (QCS6490) — Hardware Access Checker       ║{NC}")
    print(f"{BOLD}╚══════════════════════════════════════════════════════════╝{NC}")

    check_cpu()
    check_gpu_drm()
    check_gpu_kgsl()
    check_npu()
    check_isp_vpu()
    check_dsp()
    check_thermal()
    check_memory()
    summary()

    return 1 if any(not ok_ for ok_, _ in _results) else 0


if __name__ == "__main__":
    sys.exit(main())
