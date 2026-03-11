# Auto-Install And Auto-Rejoin Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make `sudo ./install.sh` the default and sufficient workflow for first-node bootstrap, later-node auto-join, and ongoing self-healing after DHCP/subnet changes, while preserving manual join secrets as explicit overrides.

**Architecture:** `install.sh` becomes a mode selector with four paths: explicit manual join, local repair, LAN auto-join, or first-node bootstrap. The init node publishes cluster metadata over Avahi/mDNS, and all nodes run a reconcile service so server and join endpoints follow IP changes automatically. Manual env vars remain authoritative and bypass discovery.

**Tech Stack:** Bash, RKE2, systemd, Avahi/mDNS, MetalLB, Traefik, Rancher, cert-manager, `kubectl`, `helm`

---

### Task 1: Add LAN Discovery Helpers

**Files:**
- Create: `scripts/cluster-discovery.sh`
- Create: `manifests/rubik-cluster-advertise.service`
- Modify: `install.sh`
- Test: `README.md`

**Step 1: Write the failing test**

Create a shell smoke-test script or at minimum define the commands that should fail before implementation:

```bash
bash -n scripts/cluster-discovery.sh
sudo ./install.sh
```

Expected before implementation:
- `scripts/cluster-discovery.sh` does not exist
- `install.sh` has no cluster auto-discovery path

**Step 2: Run test to verify it fails**

Run:

```bash
test -f scripts/cluster-discovery.sh
```

Expected: exit code non-zero because the file is absent.

**Step 3: Write minimal implementation**

Create `scripts/cluster-discovery.sh` with functions shaped like:

```bash
#!/usr/bin/env bash
set -euo pipefail

DISCOVERY_SERVICE_TYPE="_rubik-k8s._tcp"
DISCOVERY_SERVICE_NAME="${DISCOVERY_SERVICE_NAME:-rubik-cluster}"

detect_physical_interface() {
  ip route get 1.1.1.1 2>/dev/null | awk '/dev/ {for (i=1;i<=NF;i++) if ($i=="dev") print $(i+1)}' | head -1
}

advertise_mode() {
  local mode="$1"
  local token="$2"
  local short_hostname="$3"
  local txt=(
    "cluster_name=rubik-cluster"
    "mode=${mode}"
    "server_host=${short_hostname}.local"
    "server_port=9345"
    "version=1"
  )
  if [[ "$mode" == "open" ]]; then
    txt+=("token=${token}")
  fi
  printf '%s\n' "${txt[@]}"
}

discover_cluster_records() {
  avahi-browse -rtkp "${DISCOVERY_SERVICE_TYPE}" 2>/dev/null || true
}

discover_single_cluster() {
  local records
  records=$(discover_cluster_records)
  [[ -n "$records" ]] || return 1
  echo "$records"
}
```

Add a systemd service template that runs an advertiser command after Avahi is ready. Prefer an explicit helper command in `install.sh` or `scripts/cluster-discovery.sh` over inline shell in the unit.

**Step 4: Run test to verify it passes**

Run:

```bash
bash -n scripts/cluster-discovery.sh
systemd-analyze verify manifests/rubik-cluster-advertise.service
```

Expected: no syntax errors.

**Step 5: Commit**

```bash
git add scripts/cluster-discovery.sh manifests/rubik-cluster-advertise.service install.sh README.md
git commit -m "feat: add LAN discovery helpers for auto-join"
```

### Task 2: Add Install Mode Selection To `install.sh`

**Files:**
- Modify: `install.sh`
- Test: `README.md`

**Step 1: Write the failing test**

Document the desired decision order in comments and test it with controlled env vars:

```bash
CLUSTER_SERVER=https://x CLUSTER_TOKEN=y bash -n install.sh
```

Expected before implementation:
- `install.sh` still assumes “no env vars means init node”
- there is no auto-join mode selection

**Step 2: Run test to verify it fails**

Run:

```bash
rg "auto-join|manual join|reconcile" install.sh
```

Expected: no central mode-selection function exists.

**Step 3: Write minimal implementation**

Add explicit helpers:

```bash
have_local_rke2_install() {
  [[ -d "${RKE2_DATA_DIR}" || -f "${RKE2_CONFIG_DIR}/config.yaml" ]]
}

auto_discover_join_config() {
  local discovery
  discovery=$(DISCOVERY_SERVICE_TYPE="_rubik-k8s._tcp" discover_single_cluster) || return 1
  # Parse mode/server/token from TXT records here.
}

select_install_mode() {
  if [[ -n "${CLUSTER_SERVER}" && -n "${CLUSTER_TOKEN}" ]]; then
    echo "manual-join"
  elif have_local_rke2_install; then
    echo "repair"
  elif auto_discover_join_config; then
    echo "auto-join"
  else
    echo "init"
  fi
}
```

In `main()`, branch on the returned mode rather than inferring mode from `CLUSTER_SERVER` alone.

**Step 4: Run test to verify it passes**

Run:

```bash
bash -n install.sh
rg "select_install_mode|manual-join|auto-join|repair|init" install.sh
```

Expected: syntax passes and the mode-selection function is present.

**Step 5: Commit**

```bash
git add install.sh
git commit -m "feat: add installer mode selection for init join and repair"
```

### Task 3: Add Init-Node Token Advertisement Policy

**Files:**
- Modify: `install.sh`
- Modify: `README.md`
- Modify: `INSTRUCTIONS.md`

**Step 1: Write the failing test**

Define the desired prompt/env behavior:

```bash
AUTOJOIN_ADVERTISE_TOKEN=yes bash -n install.sh
AUTOJOIN_ADVERTISE_TOKEN=no bash -n install.sh
```

Expected before implementation:
- there is no `AUTOJOIN_ADVERTISE_TOKEN` variable
- init-node bootstrap never asks whether raw token advertisement is allowed

**Step 2: Run test to verify it fails**

Run:

```bash
rg "AUTOJOIN_ADVERTISE_TOKEN|Advertise raw join token" install.sh README.md INSTRUCTIONS.md
```

Expected: no matches.

**Step 3: Write minimal implementation**

Add config and prompt logic like:

```bash
AUTOJOIN_ADVERTISE_TOKEN="${AUTOJOIN_ADVERTISE_TOKEN:-}"

resolve_autojoin_policy() {
  if [[ -n "${AUTOJOIN_ADVERTISE_TOKEN}" ]]; then
    case "${AUTOJOIN_ADVERTISE_TOKEN}" in
      yes|true|1) echo "open" ;;
      no|false|0) echo "manual" ;;
      *) err "AUTOJOIN_ADVERTISE_TOKEN must be yes or no" ;;
    esac
    return
  fi

  local answer
  read -rp "Advertise raw join token over LAN for zero-config auto-join? [Y/n] " answer
  case "${answer:-Y}" in
    Y|y|yes|YES|"") echo "open" ;;
    N|n|no|NO) echo "manual" ;;
    *) err "Please answer y or n" ;;
  esac
}
```

When in init mode:
- call `resolve_autojoin_policy`
- persist the result in a file such as `/etc/rancher/rke2/autojoin-mode`
- generate the Avahi advertisement with or without the token based on that mode

**Step 4: Run test to verify it passes**

Run:

```bash
bash -n install.sh
rg "AUTOJOIN_ADVERTISE_TOKEN|Advertise raw join token|autojoin-mode" install.sh README.md INSTRUCTIONS.md
```

Expected: syntax passes and the new policy flow is documented.

**Step 5: Commit**

```bash
git add install.sh README.md INSTRUCTIONS.md
git commit -m "feat: add configurable token advertisement policy"
```

### Task 4: Implement Auto-Join From Discovery Metadata

**Files:**
- Modify: `install.sh`
- Modify: `scripts/cluster-discovery.sh`
- Test: `README.md`

**Step 1: Write the failing test**

Describe the desired behavior for both discovery modes:

```bash
# open mode
sudo ./install.sh

# manual mode
sudo ./install.sh
```

Expected before implementation:
- open mode cannot populate `CLUSTER_SERVER` and `CLUSTER_TOKEN` automatically
- manual mode cannot print a precise “cluster found, token withheld” message

**Step 2: Run test to verify it fails**

Run:

```bash
rg "mode=open|mode=manual|cluster found" install.sh scripts/cluster-discovery.sh
```

Expected: missing or incomplete.

**Step 3: Write minimal implementation**

In `scripts/cluster-discovery.sh`, parse discovery TXT data into shell-safe values:

```bash
parse_discovery_txt() {
  local line="$1"
  # Extract key=value TXT records into shell vars or a temp file.
}
```

In `install.sh`, add:

```bash
load_autojoin_from_discovery() {
  local mode server_host server_port token
  # Populate these from parsed discovery output.

  if [[ "${mode}" == "manual" ]]; then
    err "A Rubik cluster was found at https://${server_host}:${server_port}, but it does not advertise a join token. Re-run with CLUSTER_TOKEN."
  fi

  CLUSTER_SERVER="https://${server_host}:${server_port}"
  CLUSTER_TOKEN="${token}"
}
```

Require exactly one visible cluster advertisement; if multiple are found, abort with a conflict message rather than guessing.

**Step 4: Run test to verify it passes**

Run:

```bash
bash -n install.sh
bash -n scripts/cluster-discovery.sh
rg "load_autojoin_from_discovery|does not advertise a join token|multiple" install.sh scripts/cluster-discovery.sh
```

Expected: syntax passes and both open/manual discovery flows are represented.

**Step 5: Commit**

```bash
git add install.sh scripts/cluster-discovery.sh README.md
git commit -m "feat: auto-join discovered clusters by default"
```

### Task 5: Make Reconciliation Update Discovery And Reconnect Join Nodes

**Files:**
- Modify: `scripts/network-reconcile.sh`
- Modify: `install.sh`
- Modify: `manifests/rubik-network-reconcile.service`
- Test: `README.md`

**Step 1: Write the failing test**

Define two expected recoveries:

```bash
# server node IP changes
sudo /usr/local/bin/rubik-network-reconcile

# join node cannot reach old server target
sudo /usr/local/bin/rubik-network-reconcile
```

Expected before implementation:
- reconciliation does not refresh cluster advertisement data
- join nodes may still require manual rewrites to `server:`

**Step 2: Run test to verify it fails**

Run:

```bash
rg "server-ip|autodiscover_server|rubik-cluster|avahi" scripts/network-reconcile.sh
```

Expected: missing explicit discovery refresh on the server side.

**Step 3: Write minimal implementation**

On server reconciliation:
- refresh SANs using `hostname`, `hostname.local`, and current IP
- update the Avahi service metadata after any mode/IP change
- keep MetalLB/Rancher repair logic

On join-node reconciliation:
- test whether current `server:` is reachable
- if not, rediscover the cluster by Avahi
- if discovery succeeds, rewrite `server:` and, when mode is `open`, refresh token too
- restart `rke2-agent` or `rke2-server`

Representative code structure:

```bash
refresh_cluster_advertisement() {
  local mode token short_hostname
  # Rewrite Avahi service definition or restart advertiser service here.
}

reconnect_join_node() {
  if ! tcp_reachable "$current_host" 9345; then
    load_discovery_target
    rewrite_join_server "$discovered_host"
    systemctl restart rke2-agent
  fi
}
```

Also remove stale assumptions about Traefik `externalIPs`; MetalLB LoadBalancer IP should remain the canonical Rancher access path.

**Step 4: Run test to verify it passes**

Run:

```bash
bash -n scripts/network-reconcile.sh
systemd-analyze verify manifests/rubik-network-reconcile.service
rg "refresh_cluster_advertisement|reconnect_join_node|tcp_reachable" scripts/network-reconcile.sh
```

Expected: syntax passes and both server-side and join-side recovery hooks exist.

**Step 5: Commit**

```bash
git add scripts/network-reconcile.sh install.sh manifests/rubik-network-reconcile.service
git commit -m "fix: reconcile cluster discovery and join-node reconnects"
```

### Task 6: Update Documentation And Verification Matrix

**Files:**
- Modify: `README.md`
- Modify: `INSTRUCTIONS.md`
- Test: `docs/plans/2026-03-11-auto-install-design.md`

**Step 1: Write the failing test**

List the missing user-facing flows:

```bash
rg "AUTOJOIN_ADVERTISE_TOKEN|auto-join|manual join|repair mode|rubikpi.local" README.md INSTRUCTIONS.md
```

Expected before implementation: the docs do not explain the new zero-argument workflow.

**Step 2: Run test to verify it fails**

Run the command above and confirm the gaps.

**Step 3: Write minimal implementation**

Update docs to cover:
- first node: `sudo ./install.sh`
- later nodes: `sudo ./install.sh`
- how the init-node security prompt works
- how to force manual join with env vars
- how the system heals after IP changes
- what assumptions apply: same local broadcast domain, Avahi/mDNS available, one visible Rubik cluster

Add a verification checklist such as:

```markdown
- Fresh init node install with default open mode
- Fresh second node auto-join with no env vars
- Fresh second node manual join with explicit env vars
- Init node in manual advertisement mode
- Server IP change followed by automatic Rancher recovery
- Join-node reconnect after control-plane IP change
```

**Step 4: Run test to verify it passes**

Run:

```bash
rg "AUTOJOIN_ADVERTISE_TOKEN|auto-join|rubikpi.local|manual join|repair" README.md INSTRUCTIONS.md
```

Expected: all major flows are documented.

**Step 5: Commit**

```bash
git add README.md INSTRUCTIONS.md
git commit -m "docs: explain zero-config install and auto-rejoin flow"
```

### Task 7: Final Verification Pass

**Files:**
- Test: `install.sh`
- Test: `scripts/cluster-discovery.sh`
- Test: `scripts/network-reconcile.sh`
- Test: `README.md`
- Test: `INSTRUCTIONS.md`

**Step 1: Write the failing test**

Collect the exact commands that must succeed before the work is considered complete.

```bash
bash -n install.sh
bash -n scripts/cluster-discovery.sh
bash -n scripts/network-reconcile.sh
systemd-analyze verify manifests/rubik-cluster-advertise.service
systemd-analyze verify manifests/rubik-network-reconcile.service
```

Expected before implementation: one or more commands fail because the new files or logic do not exist yet.

**Step 2: Run test to verify it fails**

Run each command before implementation and capture the failures.

**Step 3: Write minimal implementation**

Do not add new product behavior here. Fix only the issues necessary to make the preceding tasks verifiable and consistent.

**Step 4: Run test to verify it passes**

Run:

```bash
bash -n install.sh
bash -n scripts/cluster-discovery.sh
bash -n scripts/network-reconcile.sh
systemd-analyze verify manifests/rubik-cluster-advertise.service
systemd-analyze verify manifests/rubik-network-reconcile.service
```

Then perform the live workflow checks:

```bash
# first node
sudo ./install.sh

# later node, no env vars
sudo ./install.sh

# later node, manual fallback
sudo CLUSTER_SERVER="https://rubikpi.local:9345" CLUSTER_TOKEN="<token>" ./install.sh
```

Expected:
- first node bootstraps correctly
- later node auto-joins when advertisement mode is `open`
- manual join still works
- Rancher remains reachable at the MetalLB-backed `nip.io` URL

**Step 5: Commit**

```bash
git add install.sh scripts/cluster-discovery.sh scripts/network-reconcile.sh manifests/rubik-cluster-advertise.service manifests/rubik-network-reconcile.service README.md INSTRUCTIONS.md
git commit -m "feat: make install.sh support zero-config cluster bootstrap and join"
```
