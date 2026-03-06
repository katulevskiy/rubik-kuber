# Rubik Pi 3 — Hardware Developer Instructions

Practical guide for getting a shell in a Kubernetes pod and using every hardware
SDK available on the QCS6490 SoC.

---

## Table of Contents

1. [Cluster Access (kubectl)](#1-cluster-access-kubectl)
2. [Interactive Session Pods](#2-interactive-session-pods)
3. [CPU Core Affinity](#3-cpu-core-affinity)
4. [Running the Hardware Benchmark](#4-running-the-hardware-benchmark)
5. [SDK Reference — CPU OpenCL (POCL)](#5-cpu-opencl-pocl)
6. [SDK Reference — GPU OpenCL (Adreno)](#6-gpu-opencl-adreno-643l)
7. [SDK Reference — NPU via QNN (Hexagon HTP)](#7-npu-qnn-hexagon-htp)
8. [SDK Reference — SNPE](#8-snpe-snapdragon-neural-processing-engine)
9. [SDK Reference — VPU (V4L2 M2M)](#9-vpu-v4l2-m2m-video-codec)
10. [SDK Reference — DSP / FastRPC](#10-dsp-fastrpc)
11. [Device Node Map](#11-device-node-map)
12. [Build the Benchmark from Source](#12-build-the-benchmark-from-source)
13. [Symlinks and Path Notes](#13-symlinks-and-path-notes)

---

## 1. Cluster Access (kubectl)

`kubectl` is symlinked from the RKE2 bundle during `install.sh`:

```
/usr/local/bin/kubectl → /var/lib/rancher/rke2/bin/kubectl
```

The `ubuntu` user gets a kubeconfig at `~/.kube/config` pointing at
`/etc/rancher/rke2/rke2.yaml`.

```bash
# Verify cluster is up
kubectl get nodes
kubectl get pods -A
```

To access the cluster from your **laptop**:

```bash
scp rubik:/etc/rancher/rke2/rke2.yaml ~/.kube/rubikpi.yaml
# Patch the server address to the Pi's real IP
sed -i 's/127.0.0.1/<rubikpi-ip>/' ~/.kube/rubikpi.yaml
export KUBECONFIG=~/.kube/rubikpi.yaml
kubectl get nodes
```

---

## 2. Interactive Session Pods

`scripts/session.sh` manages privileged pods in the `sessions` namespace.
Each pod gets a `bash` shell with:
- The entire `/dev` tree bind-mounted (GPU, NPU, VPU, DSP, ISP device nodes)
- Host `/usr/lib`, `/usr/bin`, `/lib/aarch64-linux-gnu` overlaid so all
  Qualcomm SDKs (QNN, Adreno OpenCL, FastRPC) and build tools work directly
- The `hw_bench` binary available at `/benchmark/build/hw_bench`

**Exclusive access:** when a session starts, the Pi node is tainted with
`rubikpi.ai/exclusive-session=<username>:NoSchedule`. No new workloads can
schedule there until the session is stopped, which removes the taint.

### Start a session

```bash
./scripts/session.sh start alice
```

Pin to a specific node:

```bash
./scripts/session.sh start alice --node rubikpi-2
```

Use a custom image (must be Ubuntu 24.04 or compatible — the host `/usr/lib`
overlay is ABI-safe only against Ubuntu 24.04):

```bash
SESSION_IMAGE=my-registry/rubikpi-dev:latest ./scripts/session.sh start alice
```

### Connect (interactive shell)

```bash
./scripts/session.sh connect alice
```

Drops you into `bash` inside the pod. Type `exit` or Ctrl-D to disconnect
**without** stopping the session — it keeps running.

### List all sessions

```bash
./scripts/session.sh list
```

Sessions show `[exclusive]` when their node taint is active.

### Stop a session

```bash
./scripts/session.sh stop alice
```

This deletes the pod **and removes the node taint**, releasing the Pi for
other workloads. Files written to `/root` persist at
`/var/lib/rubikpi-sessions/alice/` on the host node.

### Clean up orphaned taints

If a session pod is killed externally (not via `stop`), the taint remains:

```bash
./scripts/session.sh untaint --all
```

### One-liner: start + immediate connect

```bash
./scripts/session.sh start alice && ./scripts/session.sh connect alice
```

### Raw kubectl equivalents

```bash
# Open a shell in any running pod
kubectl exec -it session-alice -n sessions -- bash

# Watch pod events / scheduling failures
kubectl describe pod session-alice -n sessions

# Check resource allocation and taints on a node
kubectl describe node rubikpi | grep -A 10 "Allocated resources:"
kubectl get node rubikpi -o jsonpath='{.spec.taints}'
```

### Environment variables for session.sh

| Variable | Default | Description |
|---|---|---|
| `SESSION_IMAGE` | `ubuntu:24.04` | Container image (must match host OS for lib overlay) |
| `SESSION_CPU_LIM` | `6` | CPU core limit |
| `SESSION_MEM_LIM` | `8Gi` | Memory limit |
| `BENCHMARK_DIR` | `<repo>/benchmarks` | Path to benchmark dir for `/benchmark` mount |
| `KUBECONFIG` | `/etc/rancher/rke2/rke2.yaml` | kubeconfig path |

---

## 3. CPU Core Affinity

The QCS6490 / Kryo 670 has three physically distinct CPU clusters with
different micro-architectures, frequencies, and capacities:

| Type | Cores | Arch | Max freq | EAS capacity | Use for |
|---|---|---|---|---|---|
| `silver` | CPUs 0–3 | Cortex-A55 | 1.96 GHz | 382 / 1024 | background, low-power |
| `gold` | CPUs 4–6 | Cortex-A78 | 2.40 GHz | 889 / 1024 | latency-sensitive, throughput |
| `gold-plus` | CPU 7 | Cortex-A78 | 2.71 GHz | 1024 / 1024 | single-threaded peak |
| `gold-all` | CPUs 4–7 | A78 × 4 | — | — | all big cores |
| `all` | CPUs 0–7 | mixed | — | — | no affinity (default) |

### Pinning a session to a core type

Pass `--cpu-type` to `session.sh start`. The affinity is stored as a pod
annotation and applied automatically via `taskset(1)` every time you run
`session.sh connect`:

```bash
# Gold performance cores only (CPUs 4-6, Cortex-A78 @ 2.4 GHz)
./scripts/session.sh start alice --cpu-type gold

# Single Gold+ prime core (CPU 7, 2.71 GHz) — best single-thread perf
./scripts/session.sh start alice --cpu-type gold-plus

# Silver efficiency cores only (CPUs 0-3, A55 @ 1.96 GHz)
./scripts/session.sh start alice --cpu-type silver

# All big cores together (Gold + Gold+, CPUs 4-7)
./scripts/session.sh start alice --cpu-type gold-all

# Combine with node selection
./scripts/session.sh start alice --node rubikpi-3 --cpu-type gold
```

When you connect, the shell and every program it spawns are pinned:

```bash
./scripts/session.sh connect alice
# → [→] CPU affinity: gold — pinning shell to cores 4-6 via taskset
# Inside the pod, check the affinity of any process:
taskset -p $$          # current shell
taskset -p $(pgrep -n my_inference_binary)
```

### How it works

`session.sh` stores `rubikpi.ai/cpu-type` and `rubikpi.ai/cpu-cores` as pod
annotations. On `connect`, it reads them and launches:

```bash
kubectl exec -it session-alice -n sessions -- taskset -c 4-6 bash
```

`taskset` sets the CPU affinity mask of the bash process. All child processes
— compilers, runtimes, inference engines — inherit this mask via `fork()`.
The mask can be inspected or overridden at any time with `taskset -p <pid>`.

### Node labels (for scheduling or custom YAML)

`install.sh` labels every Rubik Pi node with its CPU topology:

```bash
kubectl get node rubikpi -o jsonpath='{.metadata.labels}' | tr ',' '\n' | grep cpu
# rubikpi.ai/cpu-gold-cores=4-6
# rubikpi.ai/cpu-gold-plus-cores=7
# rubikpi.ai/cpu-silver-cores=0-3
```

You can use these in your own pod YAML with `nodeSelector` or `nodeAffinity`
to schedule workloads on nodes that have a specific CPU cluster available
(useful when managing many Pis with heterogeneous hardware):

```yaml
spec:
  nodeSelector:
    rubikpi.ai/cpu-gold-cores: "4-6"   # schedule only on nodes with Gold cores
```

### Pinning within your own pod YAML (no session.sh)

For non-interactive pods, add an init container that sets the process affinity,
or simply invoke your binary via `taskset` in the container command:

```yaml
spec:
  containers:
    - name: inference
      image: my-inference-image
      command: ["taskset", "-c", "4-7", "/app/run_model"]
```

Or set affinity programmatically in C/C++ using `sched_setaffinity(2)`:

```c
#include <sched.h>

cpu_set_t gold_cores;
CPU_ZERO(&gold_cores);
CPU_SET(4, &gold_cores);  // Gold CPUs 4-6
CPU_SET(5, &gold_cores);
CPU_SET(6, &gold_cores);
sched_setaffinity(0, sizeof(gold_cores), &gold_cores);
```

### Verify affinity inside a session

```bash
# Check which CPUs your shell is allowed to run on
taskset -p $$

# Run a quick CPU-bound test and watch which cores are active
taskset -c 4-6 stress-ng --cpu 3 --timeout 5 &
cat /proc/$(pgrep stress-ng | head -1)/status | grep Cpus_allowed_list
```

---

## 4. Running the Hardware Benchmark

`hw_bench` exercises every hardware subsystem in one run and reports pass/fail
with timing. Session pods (created with `session.sh start`) already have the
binary at `/benchmark/build/hw_bench` and all SDKs available — **no setup
needed beyond starting a session**.

### Run inside a session pod (recommended)

```bash
# Terminal 1: start a session
./scripts/session.sh start alice

# Terminal 2: connect and run
./scripts/session.sh connect alice
# Now inside the pod:
/benchmark/build/hw_bench
```

### Quick run directly on the Pi host (no pod needed)

```bash
cd /path/to/rubik-kuber/benchmarks
sudo ./run.sh
# equivalent to: sudo ./build/hw_bench
```

### Expected output (tested, verified from inside a session pod)

```
╔══════════════════════════════════════════════════╗
║   Rubik Pi 3  —  SoC Hardware Benchmark          ║
╚══════════════════════════════════════════════════╝

  OpenCL (CPU + GPU)
    Platform: QUALCOMM Snapdragon(TM)  Device: QUALCOMM Adreno(TM) 643
    ✓  SAXPY 32M floats:               ~34 ms   →  ~12 GB/s
    ✓  MatMul 1024×1024 (tiled 16×16): ~499 ms  →  ~4.3 GFLOP/s
    ✓  GPU filled NV12 DMA-buf → VPU-ready

    Platform: Portable Computing Language  Device: cpu--cortex-a55
    ✓  SAXPY 4M floats:                ~4.7 ms  →  ~10 GB/s
    ✓  MatMul 512×512 (naive):         ~94 ms   →  ~2.8 GFLOP/s

  QNN Inference
    ✓  QNN-CPU    64×64 MatMul  ~0.09 ms
    ✓  QNN-HTP    64×64 MatMul  ~1.65 ms  ← NPU (Hexagon HTP)
    ✓  QNN-GPU    64×64 MatMul  ~0.58 ms

  VPU  (V4L2 M2M  msm_vidc)
    ✓  H.264 encode  640×480 NV12  ~4.3 ms  →  1040 B

  FastRPC
    ✓  CDSP  /dev/fastrpc-cdsp         open + DMA alloc OK
    ✓  ADSP  /dev/fastrpc-adsp-secure  open + DMA alloc OK

  ══════════════════════════════════════
    8 passed / 0 failed / 8 total
    All subsystems operational ✓
  ══════════════════════════════════════
```

---

## 5. CPU OpenCL (POCL)

**Package:** `pocl-opencl-icd`  
**ICD file:** `/etc/OpenCL/vendors/pocl.icd`  
**Library:** `/usr/lib/aarch64-linux-gnu/libpocl.so`

POCL provides a full OpenCL 3.0 implementation targeting the ARM CPU (all 8
Kryo 670 cores). It is selected automatically when you create an OpenCL context
with the CPU device type, or by filtering on the `"Portable Computing Language"`
platform string.

```bash
# Enumerate platforms and devices
clinfo

# Check POCL device
clinfo | grep -A 5 "Portable"
```

### Compile a minimal OpenCL program against POCL

```bash
cat > saxpy.cl << 'EOF'
__kernel void saxpy(__global float* y,
                    __global const float* x,
                    float alpha, int n) {
    int i = get_global_id(0);
    if (i < n) y[i] = alpha * x[i] + y[i];
}
EOF

cat > main.c << 'EOF'
#define CL_TARGET_OPENCL_VERSION 300
#include <CL/cl.h>
#include <stdio.h>
int main() {
    cl_platform_id plat; cl_device_id dev;
    clGetPlatformIDs(1, &plat, NULL);
    clGetDeviceIDs(plat, CL_DEVICE_TYPE_CPU, 1, &dev, NULL);
    char name[128]; clGetDeviceName(dev, sizeof(name), name, NULL);
    printf("CPU device: %s\n", name);
    return 0;
}
EOF

gcc main.c -lOpenCL -o main && ./main
```

---

## 6. GPU OpenCL (Adreno 643L)

**Package:** `qcom-adreno1`  
**ICD file:** `/etc/OpenCL/vendors/adreno.icd`  
**OpenCL loader:** `/usr/lib/aarch64-linux-gnu/libOpenCL.so.1` (provided by `qcom-adreno1`)  
**Adreno ICD:** `/usr/lib/aarch64-linux-gnu/libOpenCL_adreno.so.1`  
**Core driver:** `/usr/lib/aarch64-linux-gnu/libCB.so.1` (dynamically loaded by the ICD)  
**Linker symlink:** `/usr/lib/aarch64-linux-gnu/libOpenCL.so → libOpenCL.so.1`

The linker name `libOpenCL.so` is created by `install.sh` because
`ocl-icd-opencl-dev` (which normally creates it) conflicts with `qcom-adreno1`.
See [§12](#12-symlinks-and-path-notes) for details.

```bash
# Confirm GPU platform is enumerated
clinfo | grep -A 5 "QUALCOMM"

# Device info
clinfo | grep -E "Device Name|Max compute units|Global mem"
```

### Key Adreno OpenCL facts

| Topic | Detail |
|---|---|
| Platform string | `QUALCOMM Snapdragon(TM)` |
| Device string | `QUALCOMM Adreno(TM) 643` |
| `cl_arm_import_memory` | **Not supported** — importing DMABufs via ARM extension fails |
| `cl_qcom_dmabuf_host_ptr` | Advertised but not functional for true zero-copy on this driver |
| DMABuf workaround | `CL_MEM_USE_HOST_PTR` with `mmap`'d DMABuf address, then `clEnqueueMapBuffer(CL_MAP_READ)` to flush GPU→host |
| Best kernel type for GPU | Tiled MatMul with `__local` memory (`TILE=16`), `reqd_work_group_size(16,16,1)` |

### Compile an OpenCL program against the Adreno ICD

```bash
# -lOpenCL links against libOpenCL.so (the ICD loader)
g++ -std=c++17 myprogram.cpp -lOpenCL -o myprogram
./myprogram

# The ICD loader will enumerate both POCL (CPU) and Adreno (GPU) platforms.
# Select GPU with:
#   clGetDeviceIDs(platform, CL_DEVICE_TYPE_GPU, ...)
```

### Choose GPU platform explicitly in code

```cpp
cl_uint num_platforms;
clGetPlatformIDs(0, nullptr, &num_platforms);
std::vector<cl_platform_id> platforms(num_platforms);
clGetPlatformIDs(num_platforms, platforms.data(), nullptr);
for (auto& p : platforms) {
    char name[128]; clGetPlatformInfo(p, CL_PLATFORM_NAME, sizeof(name), name, nullptr);
    if (std::string(name).find("QUALCOMM") != std::string::npos) {
        // use this platform for GPU
    }
}
```

---

## 7. NPU — QNN (Hexagon HTP)

**Package:** `libqnn1`, `libqnn-dev`, `qnn-tools`  
**Libraries:** `/usr/lib/libQnn*.so` — one `.so` per backend  
**Headers:** `/usr/include/QNN/`, `/usr/include/HTP/`, `/usr/include/GPU/`, `/usr/include/CPU/`, `/usr/include/DSP/`  
**CLI tool:** `/usr/bin/qnn-net-run`  
**Device node:** `/dev/fastrpc-cdsp` (+ `/dev/fastrpc-cdsp-secure`)  
**Daemons required:** `cdsprpcd` (must be running — enabled by `install.sh`)

### QNN backends

| Backend library | Hardware | Notes |
|---|---|---|
| `libQnnCpu.so` | ARM CPU | Always available, no special device |
| `libQnnHtp.so` | Hexagon HTP (NPU) | Requires `/dev/fastrpc-cdsp` + `cdsprpcd` |
| `libQnnGpu.so` | Adreno GPU | Requires Adreno driver |
| `libQnnDsp.so` | Hexagon ADSP | Requires `/dev/fastrpc-adsp-secure` |

### Platform validator

```bash
qnn-platform-validator --backend /usr/lib/libQnnHtp.so
qnn-platform-validator --backend /usr/lib/libQnnCpu.so
```

### Run a model with qnn-net-run

```bash
# Build a QNN context binary from a floating-point DLC or ONNX model first:
qnn-context-binary-generator \
  --backend /usr/lib/libQnnHtp.so \
  --model my_model.so \
  --output_dir context_out

# Then run inference:
qnn-net-run \
  --backend /usr/lib/libQnnHtp.so \
  --retrieve_context context_out/my_model.bin \
  --input_list input_list.txt
```

### Using QNN in C++

Link flags:

```cmake
target_link_libraries(myapp dl)
# QNN is loaded at runtime via dlopen — no compile-time link needed
```

Runtime backend load pattern:

```cpp
#include "QnnInterface.h"
void* backend_lib = dlopen("/usr/lib/libQnnHtp.so", RTLD_NOW | RTLD_LOCAL);
QNN_INTERFACE_VER_TYPE qnn_interface;
Qnn_BackendHandle_t backend;
// ... call QnnInterface_getProviders, then backendCreate, graphCreate, etc.
```

---

## 8. SNPE (Snapdragon Neural Processing Engine)

**Package:** `libsnpe1`, `libsnpe-dev`, `snpe-tools`  
**CLI tools:** `/usr/bin/snpe-net-run`, `/usr/bin/snpe-platform-validator`, `/usr/bin/snpe-throughput-net-run`  
**Headers:** `/usr/include/SNPE/`

SNPE is the older Qualcomm inference SDK. It supports DLC model format and can
run on CPU, GPU, and DSP/HTP runtimes.

```bash
# Validate available runtimes
snpe-platform-validator

# Run a DLC model
snpe-net-run \
  --container my_model.dlc \
  --input_list input_list.txt \
  --use_gpu          # or --use_dsp, --use_cpu (default)
```

SNPE uses a simpler API than QNN and is a good choice when working with existing
`.dlc` files or GStreamer's `mlsnpe` plugin.

---

## 9. VPU — V4L2 M2M (Video Codec)

**Driver:** `msm_vidc` (in-kernel, no extra packages needed)  
**Device nodes:** `/dev/video32` (encoder), `/dev/video33` (decoder)  
**Packages:** `v4l-utils`, `gstreamer1.0-plugins-bad`

The VPU supports H.264, H.265, VP9, AV1 encode/decode via the V4L2
memory-to-memory API.

### Inspect the codec

```bash
# List all V4L2 devices
v4l2-ctl --list-devices

# Check encoder capabilities
v4l2-ctl -d /dev/video32 --list-formats-out   # OUTPUT (input frames)
v4l2-ctl -d /dev/video32 --list-formats       # CAPTURE (encoded output)

# Check what controls the encoder supports
v4l2-ctl -d /dev/video32 --list-ctrls
```

### GStreamer H.264 encode (host, no pod needed)

```bash
# Encode a test pattern to H.264
gst-launch-1.0 \
  videotestsrc num-buffers=60 ! \
  video/x-raw,width=1920,height=1080,framerate=30/1 ! \
  v4l2h264enc device=/dev/video32 ! \
  h264parse ! \
  mp4mux ! \
  filesink location=out.mp4
```

### GStreamer H.264 decode

```bash
gst-launch-1.0 \
  filesrc location=out.mp4 ! \
  qtdemux ! h264parse ! \
  v4l2h264dec device=/dev/video33 ! \
  videoconvert ! \
  autovideosink
```

### V4L2 M2M programming notes

The `msm_vidc` firmware uses `V4L2_MEMORY_MMAP` buffers for the OUTPUT queue
(input frames) — **not** `DMABUF`. The correct sequence is:

1. `VIDIOC_S_FMT` on OUTPUT (NV12) and CAPTURE (H264)
2. `VIDIOC_REQBUFS` with `V4L2_MEMORY_MMAP` on OUTPUT
3. `VIDIOC_QUERYBUF` + `mmap()` each OUTPUT buffer
4. Copy NV12 frame data into the `mmap`'d buffer
5. `VIDIOC_QBUF` the OUTPUT buffer
6. `VIDIOC_REQBUFS` + `VIDIOC_QBUF` for CAPTURE buffers
7. `VIDIOC_STREAMON` for OUTPUT and CAPTURE (do **not** call STREAMON on the
   META_CAPTURE queue — the driver manages it internally)
8. `poll()` waiting for CAPTURE readability

See `benchmarks/src/vpu_codec.cpp` for a working C++ implementation.

---

## 10. DSP — FastRPC

**Packages:** `qcom-fastrpc1`, `qcom-fastrpc-dev`  
**Kernel device:** `/dev/fastrpc-cdsp`, `/dev/fastrpc-cdsp-secure` (CDSP / Hexagon HTP)  
**Kernel device:** `/dev/fastrpc-adsp-secure` (ADSP / audio DSP)  
**Userspace libraries:** `/usr/lib/aarch64-linux-gnu/libcdsprpc.so`, `libadsprpc.so`  
**Daemons:** `cdsprpcd`, `adsprpcd`

FastRPC lets userspace code call functions that run on the Hexagon DSPs
(CDSP = compute DSP used by the HTP/NPU; ADSP = audio/sensor DSP).

### Check that daemons are running

```bash
systemctl status cdsprpcd
systemctl status adsprpcd
```

If they are not running:

```bash
sudo systemctl enable --now cdsprpcd
sudo systemctl enable --now adsprpcd
```

### Probe CDSP from userspace

```bash
# Kernel ioctl probe — checks if the device responds
python3 - << 'EOF'
import fcntl, struct, os
fd = os.open("/dev/fastrpc-cdsp", os.O_RDWR)
print("CDSP device opened OK — fd:", fd)
os.close(fd)
EOF
```

### Using FastRPC from C++

```cpp
#include <dlfcn.h>

// Load the CDSP RPC library
void* dl = dlopen("/usr/lib/aarch64-linux-gnu/libcdsprpc.so",
                  RTLD_NOW | RTLD_LOCAL);
if (!dl) { fprintf(stderr, "dlopen: %s\n", dlerror()); return -1; }

// remote_handle_open opens a FastRPC session to a DSP module
typedef int (*remote_handle_open_t)(const char* name, unsigned int* handle);
auto open_fn = (remote_handle_open_t)dlsym(dl, "remote_handle_open");

unsigned int handle;
int rc = open_fn("file:///libcdsp_default_listener.so?cdsp_domain", &handle);
printf("CDSP handle: %d  rc=%d\n", handle, rc);
```

> **Note on libadsprpc:** `remote_handle_open()` in `libadsprpc.so` can hang
> indefinitely on this system. Only use `dlopen` to verify the library loads;
> do not call `remote_handle_open` on the ADSP from a non-privileged context.
> See `benchmarks/src/fastrpc_probe.cpp` for the safe probe pattern.

---

## 11. Device Node Map

| Device node | Hardware | SDK / API |
|---|---|---|
| `/dev/dri/renderD128` | Adreno 643L GPU (render) | OpenCL (`qcom-adreno1`), Vulkan |
| `/dev/dri/card0` | Adreno 643L GPU (display) | DRM/KMS |
| `/dev/kgsl-3d0` | Adreno 643L GPU (KGSL) | Direct KGSL ioctl (Qualcomm internal) |
| `/dev/fastrpc-cdsp` | Hexagon 790 CDSP (HTP/NPU) | QNN HTP backend, libcdsprpc |
| `/dev/fastrpc-cdsp-secure` | CDSP secure world | QNN HTP (secure models) |
| `/dev/fastrpc-adsp-secure` | ADSP (audio/sensor DSP) | libadsprpc |
| `/dev/video32` | msm_vidc encoder | V4L2 M2M, GStreamer v4l2h264enc |
| `/dev/video33` | msm_vidc decoder | V4L2 M2M, GStreamer v4l2h264dec |
| `/dev/dma_heap/qcom,system` | Qualcomm system DMA heap | `DMA_HEAP_IOCTL_ALLOC` ioctl |
| `/dev/dma_heap/system` | Generic system DMA heap | `DMA_HEAP_IOCTL_ALLOC` ioctl |
| `/sys/class/thermal/thermal_zone*` | Thermal sensors | sysfs read |
| `/proc/cpuinfo` | CPU topology | sysfs read |

---

## 12. Build the Benchmark from Source

The benchmark source lives in `benchmarks/`. It requires the packages installed
by `install.sh` (QNN, POCL, Adreno OpenCL, FastRPC headers, libdrm).

```bash
cd /home/ubuntu/rubik-kuber/benchmarks

# Build
./build.sh
# → produces build/hw_bench

# Run
sudo ./run.sh
# → equivalent to: sudo ./build/hw_bench
```

### CMake flags

```bash
# Manual cmake invocation if you want to customise
cmake -S . -B build -DCMAKE_BUILD_TYPE=Release
cmake --build build -j$(nproc)
```

### Build dependencies

| Package | Provides |
|---|---|
| `cmake`, `build-essential`, `g++` | C++17 build toolchain |
| `opencl-headers`, `opencl-clhpp-headers` | `CL/cl.h`, `CL/cl.hpp` |
| `qcom-adreno1` | `libOpenCL.so.1`, `libOpenCL_adreno.so.1`, `libCB.so.1` |
| `libqnn-dev` | QNN C headers under `/usr/include/QNN/` etc. |
| `qcom-fastrpc-dev` | FastRPC C headers |
| `libdrm-dev` | `libdrm.h` for DRM device queries |
| `pocl-opencl-icd` | CPU OpenCL runtime (ICD) |

---

## How Session Pods Access Host Libraries

Session pods do not use a custom container image. Instead, they overlay key
directories from the host into the container so all Qualcomm SDKs are
immediately available:

| Volume | Host path | Container path | Purpose |
|---|---|---|---|
| `host-usr-bin` | `/usr/bin` | `/usr/bin` | Build tools: `ld`, `gcc`, `cmake`, etc. (needed by POCL JIT) |
| `host-usr-lib` | `/usr/lib` | `/usr/lib` | QNN, Adreno OpenCL, FastRPC, POCL libraries |
| `host-lib-multiarch` | `/lib/aarch64-linux-gnu` | `/lib/aarch64-linux-gnu` | C runtime (glibc, etc.) |
| `host-opencl-icd` | `/etc/OpenCL` | `/etc/OpenCL` | ICD config for Adreno GPU + POCL CPU |
| `host-pocl-share` | `/usr/share/pocl` | `/usr/share/pocl` | POCL runtime headers for kernel JIT |
| `dev` | `/dev` | `/dev` | All hardware device nodes |
| `benchmark` | `<repo>/benchmarks` | `/benchmark` | `hw_bench` binary (read-only) |

**Why overlay instead of a custom image?** The host already has all Qualcomm
packages installed by `install.sh`. An overlay means zero image-build time and
automatic updates when host packages are upgraded.

**ABI safety:** The default image is `ubuntu:24.04`, matching the host OS.
The host's glibc (2.39) replaces the container's glibc via the overlay.
Since the overlay version matches the image version, there are no ABI
compatibility issues.

---

## 13. Symlinks and Path Notes

Two symlinks were created during initial setup and are now reproduced by
`install.sh` on every fresh node:

### `/usr/local/bin/kubectl → /var/lib/rancher/rke2/bin/kubectl`

Created by the `setup_kubectl()` step in `install.sh`.  
Puts `kubectl` on `$PATH` without needing to export `PATH` manually.

```bash
# Verify
ls -la /usr/local/bin/kubectl
which kubectl
```

### `/usr/lib/aarch64-linux-gnu/libOpenCL.so → libOpenCL.so.1`

Created by the `install_qcom_hw_stack()` step in `install.sh`.

**Why this is needed:** `qcom-adreno1` ships `libOpenCL.so.1` (the runtime
shared library) but NOT `libOpenCL.so` (the bare linker name that the compiler
looks for when you pass `-lOpenCL`).

Normally `ocl-icd-opencl-dev` provides this symlink — but that package
**conflicts** with `qcom-adreno1`: installing it would replace the Adreno ICD
with the generic one and remove the GPU OpenCL driver.

The fix in `install.sh`:

```bash
ln -sf libOpenCL.so.1 /usr/lib/aarch64-linux-gnu/libOpenCL.so
```

This lets `g++ myprogram.cpp -lOpenCL` link correctly while keeping Adreno GPU
OpenCL operational.

```bash
# Verify
ls -la /usr/lib/aarch64-linux-gnu/libOpenCL.so*
# Expected:
#   libOpenCL.so      → libOpenCL.so.1         (linker name, our symlink)
#   libOpenCL.so.1    → libOpenCL.so.1.0.0     (SONAME, from qcom-adreno1)
#   libOpenCL.so.1.0.0                          (actual library, from qcom-adreno1)
```
