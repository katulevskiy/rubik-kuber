# Rubik Pi 3 — Kubernetes Cluster (RKE2)

One-script RKE2 Kubernetes setup for one or many **Qualcomm Rubik Pi 3** devices
(QCS6490 SoC). Run the same script on every Pi — it figures out whether to bootstrap
a new cluster or join an existing one.

Installed automatically:
- [RKE2](https://docs.rke2.io/) (Kubernetes distribution)
- [MetalLB](https://metallb.universe.tf/) (bare-metal LoadBalancer)
- [Traefik](https://traefik.io/) (ingress controller, default IngressClass)
- [cert-manager](https://cert-manager.io/) (certificate management)
- [Rancher](https://rancher.com/) (cluster management UI)
- Qualcomm hardware device plugin (GPU / NPU / ISP / VPU per node)

---

## Requirements

- Qualcomm Rubik Pi 3 (QCS6490 / Dragonwing) running Ubuntu 22.04 or 24.04
- SSH access (`ssh rubik` → `ubuntu` user with passwordless sudo)
- Internet access on each Pi (to pull packages and container images)
- A block of free IPs on your LAN for MetalLB (e.g. `192.168.1.200-192.168.1.220`)
- Qualcomm firmware package for GPU/VPU initialisation:

```bash
sudo apt install linux-firmware
```

---

## Quick Start — Single Pi

```bash
# Clone the repo onto the Pi
git clone https://github.com/your-org/rubik-kubernetes.git
cd rubik-kubernetes

# Bootstrap the cluster (prompts for MetalLB IP range if not set)
sudo ./install.sh
```

At the end the script prints the Rancher URL and the join command for additional nodes.

---

## Multi-Node Cluster

Run the **same script** on every Pi. The only difference is the environment variables.

### Step 1 — Init node (first Pi)

```bash
# Optional: set MetalLB range as an env var to skip the prompt
sudo METALLB_RANGE="192.168.1.200-192.168.1.220" ./install.sh
```

When it completes you will see output like:

```
╔══════════════════════════════════════════════════════════╗
║        Rubik Pi 3 — Cluster Bootstrap Complete          ║
╚══════════════════════════════════════════════════════════╝

  Rancher UI:   https://rancher.192.168.1.200.nip.io
  Password:     rubikpi-admin

  To join more nodes, run on each Pi:

  sudo CLUSTER_SERVER="https://192.168.1.10:9345" \
       CLUSTER_TOKEN="a3f9..." \
       ./install.sh

  Token (save this!):
  a3f9c1e2d4b7...
```

### Step 2 — Join additional Pis

Copy the join command from the init node output and run it on every other Pi:

```bash
sudo CLUSTER_SERVER="https://192.168.1.10:9345" \
     CLUSTER_TOKEN="a3f9c1e2d4b7..." \
     ./install.sh
```

That's it. The Qualcomm device plugin DaemonSet automatically schedules on every
new node that joins — no extra steps required.

### Choosing node roles

| Role | Command | When to use |
|---|---|---|
| `server` (default) | *(no extra flags)* | Control plane + etcd + workloads |
| `agent` | `CLUSTER_ROLE=agent` | Pure worker, no etcd overhead |

For **etcd HA** keep the total number of server nodes **odd** (1, 3, 5).
For clusters with 4+ Pis, run 3 servers and add the rest as agents:

```bash
# Nodes 1–3: server (control plane)
sudo CLUSTER_SERVER="..." CLUSTER_TOKEN="..." ./install.sh

# Nodes 4–N: agent (worker only)
sudo CLUSTER_SERVER="..." CLUSTER_TOKEN="..." CLUSTER_ROLE=agent ./install.sh
```

> **Note:** RKE2 server nodes carry **no taints** by default — they run regular
> workloads just like agent nodes.

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `CLUSTER_SERVER` | *(absent = init mode)* | `https://<init-node-ip>:9345` |
| `CLUSTER_TOKEN` | — | Token printed by the init node |
| `CLUSTER_ROLE` | `server` | `server` or `agent` |
| `METALLB_RANGE` | *(prompted)* | Free IP range on your LAN |
| `RANCHER_PASSWORD` | `rubikpi-admin` | Rancher bootstrap password |

---

## Interactive Hardware Sessions

Session pods give users an interactive bash shell with **full access to all
hardware interfaces** on whichever Pi the pod is scheduled on. Each session is
**exclusive**: the Pi node is tainted when the session starts, blocking any other
workload from scheduling there until the session is stopped.

All Qualcomm SDKs (QNN, Adreno OpenCL, FastRPC) are available immediately —
host libraries are overlaid into the pod, so no custom image is needed.
The `hw_bench` binary is pre-mounted at `/benchmark/build/hw_bench`.

### Start a session

```bash
./scripts/session.sh start alice
```

The scheduler automatically places the pod on a node that has available GPU, NPU,
and VPU resources (all three are consumed so no other pod can use the hardware).
Once running:

```
Session 'alice' is ready
  Node:  rubikpi-3
  Image: ubuntu:22.04

  Connect:  ./scripts/session.sh connect alice
  Stop:     ./scripts/session.sh stop alice

  Hardware available inside the session:
    GPU  — /dev/dri/renderD128  (Adreno 643L)
    NPU  — /dev/fastrpc-cdsp   (Hexagon CDSP)
    ISP  — /dev/video0 ...     (Spectra 570L cameras)
    VPU  — /dev/video10 ...    (Adreno VPU633 codec)
    CPU  — 8 cores (Kryo 670)
```

### Connect (interactive shell)

```bash
./scripts/session.sh connect alice
```

This drops you into a `bash` shell inside the pod. Type `exit` or Ctrl-D to
disconnect — the session **keeps running** until explicitly stopped.

### Pin a session to a specific node

```bash
./scripts/session.sh start alice --node rubikpi-2
```

### List all sessions

```bash
./scripts/session.sh list
```

```
Active sessions:

  USER                 POD                            STATUS     NODE                 AGE
  ──────────────────── ────────────────────────────── ────────── ──────────────────── ───
  alice                session-alice                  Running    rubikpi-2            45m
  bob                  session-bob                    Running    rubikpi-4            12m
```

### Stop a session

```bash
./scripts/session.sh stop alice
```

This deletes the pod **and removes the node taint**, releasing the Pi for
other workloads. Files saved under `/root` persist on the host node at
`/var/lib/rubikpi-sessions/alice/`.

### Clean up orphaned taints

If a pod was killed externally (not via `stop`), the exclusive taint stays
on the node. Remove it with:

```bash
./scripts/session.sh untaint --all
```

### Session environment variables

| Variable | Default | Description |
|---|---|---|
| `SESSION_IMAGE` | `ubuntu:24.04` | Container image (must match host OS) |
| `SESSION_CPU_LIM` | `6` | CPU cores limit per session |
| `SESSION_MEM_LIM` | `8Gi` | Memory limit per session |
| `BENCHMARK_DIR` | `<repo>/benchmarks` | Path to benchmarks dir for `/benchmark` mount |

---

## Hardware Resources

Each Pi exposes the following Kubernetes resources via the device plugin:

| Resource | Device nodes | Hardware |
|---|---|---|
| `rubikpi.ai/gpu` | `/dev/dri/renderD128`, `/dev/dri/card0` | Adreno 643L GPU |
| `rubikpi.ai/npu` | `/dev/fastrpc-cdsp` | Hexagon CDSP (AI Engine) |
| `rubikpi.ai/isp` | `/dev/video0` | Spectra 570L ISP |
| `rubikpi.ai/vpu` | `/dev/video10` | Adreno VPU633 (video codec) |

Request them in any workload pod:

```yaml
resources:
  limits:
    rubikpi.ai/gpu: "1"
    rubikpi.ai/npu: "1"
```

Session pods request **all three hardware resources** (`rubikpi.ai/gpu`,
`rubikpi.ai/npu`, `rubikpi.ai/video`) and also taint the node, ensuring
**exclusive** access to the entire Pi for the duration of the session.

---

## Accessing Rancher

Rancher is exposed via Traefik on a `nip.io` hostname derived from the MetalLB IP:

```
https://rancher.<traefik-ip>.nip.io
```

The exact URL is printed at the end of `install.sh`. Accept the self-signed
certificate in your browser.

Default credentials:
- Username: `admin`
- Password: `rubikpi-admin` (or what you set in `RANCHER_PASSWORD`)

---

## Cluster Access (kubectl)

After running `install.sh`, `kubectl` is available for the `ubuntu` user:

```bash
kubectl get nodes
kubectl get pods -A
```

The kubeconfig is at `/etc/rancher/rke2/rke2.yaml` (root) and
`~/.kube/config` (ubuntu user).

To access the cluster from your laptop, copy the kubeconfig:

```bash
scp rubik:/etc/rancher/rke2/rke2.yaml ~/.kube/rubikpi.yaml
# Replace the server IP in the file if needed:
sed -i 's/127.0.0.1/<rubikpi-ip>/' ~/.kube/rubikpi.yaml
export KUBECONFIG=~/.kube/rubikpi.yaml
kubectl get nodes
```

---

## Developer Instructions

For detailed instructions on how to:

- Get an interactive shell inside a pod
- Run the hardware benchmark (`hw_bench`)
- Use each SDK (GPU/CPU OpenCL, QNN/NPU, SNPE, VPU, FastRPC/DSP)
- Understand all available device nodes
- Build the benchmark from source
- Why certain symlinks exist and what they do

→ **[INSTRUCTIONS.md](INSTRUCTIONS.md)**

---

## Repository Structure

```
rubik-kubernetes/
├── install.sh                        # Cluster installer (init + join)
├── scripts/
│   └── session.sh                    # Interactive session manager
├── manifests/
│   ├── qualcomm-device-plugin.yaml   # GPU/NPU/ISP/VPU device plugin DaemonSet
│   └── session-rbac.yaml             # sessions namespace + RBAC
├── benchmarks/
│   ├── src/                          # C++ hardware benchmark source
│   ├── build.sh                      # Build script
│   ├── run.sh                        # Run script (host)
│   └── CMakeLists.txt
├── INSTRUCTIONS.md                   # SDK usage & pod shell guide
└── README.md
```

---

## Troubleshooting

### RKE2 fails to start

```bash
journalctl -u rke2-server -f
journalctl -u rke2-agent  -f
```

### GPU / NPU devices not showing up

```bash
# Check GPU driver
ls /dev/dri/
dmesg | grep -i adreno

# Check NPU / fastrpc
ls /dev/fastrpc*
dmesg | grep fastrpc

# Install firmware if missing
sudo apt install linux-firmware
sudo reboot
```

### Device plugin not advertising resources

```bash
kubectl get pods -n kube-system -l app=qualcomm-device-plugin
kubectl logs -n kube-system -l app=qualcomm-device-plugin
kubectl describe node <nodename> | grep -A 20 "Allocatable:"
```

### Rancher UI not accessible

```bash
# Check Traefik got a LoadBalancer IP
kubectl get svc -n traefik

# Check Rancher pods
kubectl get pods -n cattle-system
kubectl logs -n cattle-system -l app=rancher

# Check cert-manager
kubectl get pods -n cert-manager
```

### Session pod stuck in Pending

```bash
kubectl describe pod session-<username> -n sessions
# Usually: no node with available GPU/NPU resources
kubectl describe node | grep -A 5 "Allocated resources"
```
