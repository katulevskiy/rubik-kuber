# Auto-Install And Auto-Rejoin Design

**Date:** 2026-03-11

**Goal:** Make `install.sh` the primary install path for both new and existing Rubik Pi clusters so that:
- the first node can bootstrap with `sudo ./install.sh`
- later nodes can join with `sudo ./install.sh`
- manual join secrets still remain available as explicit overrides
- server and worker nodes recover automatically from DHCP/subnet changes without human edits

## Requirements

- Same local broadcast domain is sufficient; no corporate-network or routed discovery is required.
- Zero-config join should be the default user experience.
- Manual join using `CLUSTER_SERVER` and `CLUSTER_TOKEN` must remain supported.
- The init node must ask whether to advertise the raw join token unless `AUTOJOIN_ADVERTISE_TOKEN` is already set.
- Rancher should continue to live at a stable MetalLB-backed `nip.io` URL rather than a node DHCP IP.
- Existing clusters must keep working when node IPs change.

## Recommended Architecture

The system should use a hybrid bootstrap model:

1. **Manual override mode**
   If `CLUSTER_SERVER` and `CLUSTER_TOKEN` are set, `install.sh` performs an explicit manual join and skips all discovery logic.

2. **Local repair mode**
   If the node already has an RKE2 installation, `install.sh` should repair/reconcile the local node instead of trying to create a new cluster or blindly rejoin.

3. **Auto-join mode**
   If no local RKE2 installation exists but a Rubik cluster advertisement is visible on the LAN, `install.sh` should auto-join that cluster.

4. **Init mode**
   If no local install exists and no cluster advertisement is visible, `install.sh` should bootstrap a new cluster and begin advertising it.

This preserves manual control while making zero-argument install the normal path.

## Discovery Model

Use Avahi/mDNS service discovery on the local broadcast domain.

### Advertised service

The init node should advertise a DNS-SD service such as `_rubik-k8s._tcp` on port `9345` with TXT metadata:

- `cluster_name=<name>`
- `mode=open|manual`
- `server_host=rubikpi.local`
- `server_port=9345`
- `token=<raw token>` only when auto-join is enabled
- `version=<installer version or schema version>`

The join endpoint should be a hostname, not a DHCP IP. `rubikpi.local` is the preferred control-plane endpoint because it remains stable while the physical IP changes underneath.

### Security toggle

When the node is about to become the init node:

- If `AUTOJOIN_ADVERTISE_TOKEN` is set, use that value.
- Otherwise prompt:
  `Advertise raw join token over LAN for zero-config auto-join? [Y/n]`

Behavior:

- `yes` or default:
  advertise `mode=open` and include the raw token in TXT records.
- `no`:
  advertise `mode=manual` and omit the token. New nodes can still discover the cluster endpoint but must use manual join secrets.

## Init Node Behavior

When initializing a new cluster:

1. Detect the physical node IP.
2. Auto-derive the MetalLB range from that subnet unless `METALLB_RANGE` overrides it.
3. Write RKE2 config with SANs for:
   - current node IP
   - short hostname
   - `<short-hostname>.local`
   - FQDN
4. Install RKE2, MetalLB, Traefik, cert-manager, Rancher, Longhorn, hardware stack, and session tooling.
5. Restrict Avahi advertisement to physical interfaces so `.local` resolves to the real LAN IP rather than Docker/Flannel addresses.
6. Publish the Rubik cluster discovery record over mDNS.
7. Install a reconciliation service that updates all derived state when IPs change.

## Join Node Behavior

When a new node runs `sudo ./install.sh`:

1. If manual env vars are present, use them directly.
2. Otherwise query Avahi for `_rubik-k8s._tcp`.
3. If a single healthy cluster advertisement is found:
   - read `server_host`, `server_port`, `mode`, and optionally `token`
   - if `mode=open`, write `server: "https://rubikpi.local:9345"` and the discovered token into `config.yaml`
   - if `mode=manual`, print a clear message that the cluster was found but manual `CLUSTER_TOKEN` is required
4. Install RKE2 in server or agent mode according to `CLUSTER_ROLE`.
5. Install the same local reconcile service so this node can later heal itself if its own IP changes or the server endpoint changes.

## Resilience Design

### Control-plane node

The existing `network-reconcile` concept remains the basis of self-healing and should ensure:

- RKE2 `config.yaml` SANs match the current node IP/hostname
- etcd peer membership is reset when the stored peer IP goes stale
- MetalLB pool follows the current subnet
- Traefik external IP state is cleaned up
- Rancher hostname, ingress, and `server-url` are updated to the current LoadBalancer IP
- cluster advertisement metadata stays current

### Join nodes

Join nodes should self-heal by:

- checking whether the configured `server:` target is reachable
- re-resolving `rubikpi.local` and/or the Rubik cluster advertisement when it is not
- rewriting `server:` automatically if the target changed
- restarting `rke2-agent` or `rke2-server` as needed

This ensures that adding a new node weeks later still works with `sudo ./install.sh`, even if the init node has moved to a different DHCP IP since the cluster was first installed.

## Failure Handling

- **No discovery record found:** assume this node should bootstrap a new cluster.
- **Discovery record found but no token advertised:** print that the cluster is in manual-join mode and require explicit env vars.
- **Multiple discovery records found:** abort with a clear conflict message; do not guess which cluster to join.
- **`.local` resolves to the wrong interface:** Avahi config must be repaired automatically on the init node to advertise only physical LAN interfaces.
- **Rancher/MetalLB stale after IP changes:** reconciliation should update them on every boot and when `install.sh` is re-run.

## Files To Change

- `install.sh`
- `scripts/network-reconcile.sh`
- `README.md`
- `INSTRUCTIONS.md` if operational instructions change
- new discovery helper/service files, likely under:
  - `scripts/`
  - `manifests/`

## Verification Strategy

1. Fresh first-node install with `sudo ./install.sh`
2. Fresh second-node install with `sudo ./install.sh`
3. Fresh second-node install with manual env vars
4. Init-node install with `AUTOJOIN_ADVERTISE_TOKEN=no`
5. IP-change recovery on init node
6. IP-change recovery on a joined node
7. Rancher remains reachable at `https://rancher.<metallb-ip>.nip.io`
8. Existing hardware session workflow still functions after reconciliation changes

## Out Of Scope

- Cross-subnet discovery
- Internet-based bootstrap
- Multi-cluster federation
- Strongly secured bootstrap transport beyond the explicit `open` vs `manual` LAN choice
