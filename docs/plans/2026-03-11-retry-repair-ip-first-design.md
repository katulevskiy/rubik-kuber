# Retry And IP-First Repair Design

**Date:** 2026-03-11

**Goal:** Make joined-node recovery resilient when local join configuration is stale, especially when it contains a hostname that no longer resolves on the node.

## Problem

Joined nodes currently enter `REPAIR` mode when a local RKE2 install already exists. In that path, `install.sh` preserves the existing `server:` value from `/etc/rancher/rke2/config.yaml` and writes it back into the refreshed config.

That is unsafe when the stored endpoint is stale, for example:

- `server: "https://rubikpi.local:9345"`
- `.local` name resolution is not functional on the node
- the init node is already advertising a valid joinable cluster over LAN discovery

In that situation, repeated `sudo ./install.sh` runs keep reapplying the broken endpoint instead of healing it.

## Requirements

- Normal `sudo ./install.sh` reruns on joined nodes should self-heal stale endpoints by default.
- Join transport should prefer the discovered server IP, not require a hostname.
- `--retry` should be available as an explicit stronger recovery path.
- Hostnames may vary between installations and must not be a hard dependency for cluster join.
- Discovery remains local-LAN only and must still refuse to guess when multiple clusters are visible.
- Manual join credentials must remain supported.

## Design

### Repair mode

When `install.sh` detects a joined node in `REPAIR` mode:

1. Read the existing local `server:` and `token:` values.
2. Attempt LAN discovery again.
3. If discovery succeeds:
   - prefer the advertised IP endpoint for `server:`
   - if discovery mode is `open`, refresh the token from discovery too
   - if discovery mode is `manual`, keep the local token but still refresh the endpoint
4. If discovery does not succeed:
   - keep the existing local endpoint and token
   - continue with repair without guessing

This makes standard repair runs self-healing without making discovery mandatory for every rerun.

### Retry mode

`sudo ./install.sh --retry` is a stronger joined-node recovery mode.

For joined nodes:

1. Ignore the existing local join endpoint as authoritative.
2. Re-run LAN discovery and require a single valid cluster candidate.
3. If discovery mode is `open`, use the discovered IP endpoint and token.
4. If discovery mode is `manual`, stop with a direct error instructing the user to provide explicit credentials.
5. Rewrite local join config from the resolved values and restart the local RKE2 agent/server service.

This gives users a deterministic “throw away stale local endpoint state and rediscover the real cluster” escape hatch.

## Error Handling

- Multiple visible clusters: fail closed, do not guess.
- Malformed or unavailable discovery during default repair: continue with existing local config.
- Malformed or unavailable discovery during `--retry`: fail with an explicit recovery message.
- Manual discovery mode during `--retry`: fail with an explicit message requiring `CLUSTER_SERVER` and `CLUSTER_TOKEN`.

## Testing

Add regression coverage for:

- repair mode refreshing a stale hostname endpoint to the discovered IP
- repair mode keeping the existing token when discovery is manual
- `--retry` parsing and activation
- retry/repair helper behavior when discovery is absent
