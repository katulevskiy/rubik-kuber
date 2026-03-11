# CPU Topology Auto-Labeling Design

**Date:** 2026-03-11

**Goal:** Ensure every Rubik node automatically receives the fixed CPU topology labels used by session affinity workflows, including later agent nodes that do not have local cluster-admin kubeconfig access.

## Problem

`install.sh` currently tries to label the local node directly with:

- `rubikpi.ai/cpu-silver-cores=0-3`
- `rubikpi.ai/cpu-gold-cores=4-6`
- `rubikpi.ai/cpu-gold-plus-cores=7`

That works on control-plane nodes with working `kubectl`, but later agent nodes often miss the labels because they do not have a local kubeconfig that can update node metadata.

## Requirements

- Labeling must become fully automatic for future later-node joins.
- Existing local labeling attempts may remain as a best-effort fast path.
- The reliable path must not depend on node hostnames, SSH, or manual `kubectl`.
- Affinity sessions on any node, including `rubik3`, must remain verifiable from inside a pod.

## Design

Install a small Kubernetes DaemonSet with a service account that can patch node labels.

Each pod:

1. Reads its own node name from `spec.nodeName`.
2. Calls the Kubernetes API with its in-cluster service account token.
3. Applies the fixed Rubik CPU topology labels to that node.
4. Sleeps and rechecks periodically so re-created nodes or cleared labels self-heal.

## Why this approach

- It is automatic for future nodes as soon as the DaemonSet schedules there.
- It works equally on init nodes, joined agents, and joined servers.
- It avoids relying on local admin kubeconfig on agent nodes.
- It uses the cluster itself as the source of truth, which is more reliable than asking the joining host to label itself externally.

## Verification

After applying the labeler:

1. Confirm `rubik3` has all three CPU topology labels.
2. Start a session pod on `rubik3` with `--cpu-type silver` or `gold`.
3. Run `taskset -p $$` and inspect `/proc/self/status` inside the pod shell to confirm the affinity mask matches the requested CPU set.
