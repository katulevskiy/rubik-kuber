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

# Bootstrap the cluster
sudo ./install.sh
```

On a brand-new init node, `install.sh` also asks whether to advertise the raw join
token over LAN for zero-config auto-join:

```text
Advertise raw join token over LAN for zero-config auto-join? [Y/n]
```

Press Enter or answer `Y` to advertise in `open` mode, or answer `n` to keep LAN
discovery in `manual` mode. The selected mode is persisted at
`/etc/rancher/rke2/autojoin-mode`.

For non-interactive first bootstrap runs, set `AUTOJOIN_ADVERTISE_TOKEN=yes` or
`AUTOJOIN_ADVERTISE_TOKEN=no` explicitly. The installer now fails closed instead
of defaulting the policy when no TTY is available.

At the end the script prints the Rancher URL and the join command for additional nodes.

---

## Multi-Node Cluster

Run the **same script** on every Pi. Later nodes can usually just run `sudo ./install.sh`
with no join env vars when the init node advertises discovery in `open` mode.

### Step 1 — Init node (first Pi)

Default interactive bootstrap:

```bash
sudo ./install.sh
```

That first init-node run installs the cluster, auto-derives `METALLB_RANGE` when
unset, and asks whether the raw join token may be advertised on the LAN.

Non-interactive bootstrap example:

```bash
# Optional: set both env vars to skip prompts on first bootstrap
sudo METALLB_RANGE="192.168.1.200-192.168.1.220" \
     AUTOJOIN_ADVERTISE_TOKEN=yes \
     ./install.sh
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

Default path when the init node uses discovery `open` mode:

```bash
sudo ./install.sh
```

If the discovered cluster advertises `manual` mode instead, the installer prints the
discovered `CLUSTER_SERVER` value and stops until you provide explicit join env vars.

Manual override path on any node, including when discovery is unavailable or when you
want to bypass discovery entirely:

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
| `agent` (default for later joins) | *(no extra flags for later nodes)* | Pure worker, no etcd overhead |
| `server` | `CLUSTER_ROLE=server` | Control plane + etcd + workloads |

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

## Auto-Install Assumptions

The zero-argument `sudo ./install.sh` flow assumes:

- all Pis are on the same local broadcast domain
- Avahi/mDNS discovery is available on that LAN segment
- only one Rubik cluster is visible to discovery at a time

If those assumptions are not true, use the manual join env vars instead of relying on
discovery.

---

## Environment Variables

| Variable | Default | Description |
|---|---|---|
| `CLUSTER_SERVER` | *(absent = auto-select mode)* | Manual join server override such as `https://<init-node-short-hostname>.local:9345` |
| `CLUSTER_TOKEN` | — | Manual join token override from the init node |
| `CLUSTER_ROLE` | `agent` for joins | Join-role override: `agent` or `server` |
| `METALLB_RANGE` | *(auto-derived when unset)* | Free IP range on your LAN |
| `AUTOJOIN_ADVERTISE_TOKEN` | *(prompted on first init bootstrap)* | `yes` = advertise raw token (`open`), `no` = advertise manual-only discovery |
| `RANCHER_PASSWORD` | `rubikpi-admin` | Rancher bootstrap password |

---

## Repair And IP-Change Self-Healing

Once a node has already been installed, re-running:

```bash
sudo ./install.sh
```

does not create a second cluster. The installer switches to local repair/reconcile
mode, refreshes the node's local configuration, and re-installs the reconcile service.

The control-plane endpoint is advertised as
`<current-short-hostname>.local` on the init node, so later nodes do not need to
hard-code a DHCP address. For example, a node whose short hostname is
`rubikpi` would advertise `rubikpi.local`. If the init node IP changes, the
reconcile flow updates the local RKE2 server address, re-publishes the LAN
discovery record, and re-applies the cluster-facing bits that depend on the
node IP. Re-running `sudo ./install.sh` is also a safe manual recovery step
after network changes.

---

## Verification Matrix

Use this checklist when validating the auto-install / auto-rejoin flow:

| Scenario | Command | Expected result |
|---|---|---|
| Fresh first node, interactive | `sudo ./install.sh` | Auto-derives `METALLB_RANGE`, prompts for the init-node `AUTOJOIN_ADVERTISE_TOKEN` policy, then bootstraps the cluster |
| Fresh first node, non-interactive open mode | `sudo AUTOJOIN_ADVERTISE_TOKEN=yes ./install.sh` | Boots without prompting for advertisement policy and publishes zero-config auto-join |
| Fresh first node, non-interactive manual mode | `sudo AUTOJOIN_ADVERTISE_TOKEN=no ./install.sh` | Boots without prompting for advertisement policy and withholds the raw join token |
| Fresh later node, zero-arg join | `sudo ./install.sh` | Discovers the cluster and joins automatically as an `agent` when the init node advertises `open` mode |
| Fresh later node, manual fallback | `sudo CLUSTER_SERVER="https://<init-node-short-hostname>.local:9345" CLUSTER_TOKEN="<token>" ./install.sh` | Joins with explicit credentials even if discovery is unavailable or manual-only |
| Existing node after network/IP change | `sudo ./install.sh` | Enters repair/reconcile mode and refreshes local config instead of bootstrapping a new cluster |
| Control-plane IP change | `sudo ./install.sh` on the init node, then `sudo ./install.sh` on later nodes if needed | `<current-short-hostname>.local` discovery and cluster access recover without replacing the cluster |

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

### Pin a session to a specific CPU core type

The QCS6490 / Kryo 670 has three CPU clusters. Use `--cpu-type` to restrict the
interactive shell (and all programs it spawns) to one cluster:

| Flag | Cores | Architecture | Frequency |
|---|---|---|---|
| `--cpu-type silver` | 0–3 | Cortex-A55 | 1.96 GHz (efficiency) |
| `--cpu-type gold` | 4–6 | Cortex-A78 | 2.40 GHz (performance) |
| `--cpu-type gold-plus` | 7 | Cortex-A78 | 2.71 GHz (prime / boost) |
| `--cpu-type gold-all` | 4–7 | Cortex-A78 × 4 | all big cores |
| `--cpu-type all` | 0–7 | — | no affinity (default) |

```bash
# Benchmark workload on Gold performance cores only
./scripts/session.sh start alice --cpu-type gold

# Isolate to the single Gold+ prime core for single-thread perf testing
./scripts/session.sh start alice --cpu-type gold-plus

# Combine with node selection
./scripts/session.sh start alice --node rubikpi-3 --cpu-type gold
```

`session.sh connect` applies `taskset(1)` automatically based on the
`--cpu-type` used at start. See [INSTRUCTIONS.md](INSTRUCTIONS.md#3-cpu-core-affinity)
for details including `sched_setaffinity` API usage and raw pod YAML patterns.

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
