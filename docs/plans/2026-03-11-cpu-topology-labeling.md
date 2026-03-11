# CPU Topology Auto-Labeling Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Automatically apply Rubik CPU topology labels to every node, including later agent nodes, and verify affinity from within a session pod on `rubik3`.

**Architecture:** Keep the existing direct local labeling attempt, but add a cluster-installed DaemonSet that uses in-cluster credentials to patch the fixed CPU topology labels onto whichever Rubik node it runs on. The installer applies this manifest on the control plane, and the live cluster can be updated by applying the same manifest immediately.

**Tech Stack:** Bash, Kubernetes manifests, service accounts/RBAC, DaemonSet, `kubectl`, session affinity tooling

---

### Task 1: Add failing regression coverage for automatic CPU topology labeling

**Files:**
- Create: `tests/cpu-topology-labeler.sh`
- Modify: `install.sh`
- Test: `manifests/cpu-topology-labeler.yaml`

**Step 1: Write the failing test**

Assert that:

- the manifest exists
- it includes a DaemonSet and RBAC
- it patches the three Rubik CPU topology labels
- `install.sh` applies the manifest during server-side installation

**Step 2: Run test to verify it fails**

Run: `bash tests/cpu-topology-labeler.sh`

Expected: FAIL before the manifest and installer hook exist.

**Step 3: Write minimal implementation**

Add the manifest and the installer function that applies it.

**Step 4: Run test to verify it passes**

Run: `bash tests/cpu-topology-labeler.sh`

Expected: PASS

### Task 2: Install the cluster-side labeler from the installer

**Files:**
- Modify: `install.sh`
- Create: `manifests/cpu-topology-labeler.yaml`

**Step 1: Write the failing test**

Reuse the regression above so it proves the installer applies the manifest.

**Step 2: Run test to verify it fails**

Run: `bash tests/cpu-topology-labeler.sh`

Expected: FAIL

**Step 3: Write minimal implementation**

- add `install_cpu_topology_labeler()`
- call it from the server-side install path
- keep `label_node_cpu_topology()` as a best-effort direct label attempt

**Step 4: Run test to verify it passes**

Run: `bash tests/cpu-topology-labeler.sh`

Expected: PASS

### Task 3: Verify on the live cluster and within a pod on `rubik3`

**Files:**
- Modify: none
- Test: live cluster

**Step 1: Apply the manifest to the live cluster**

Run: `kubectl apply -f manifests/cpu-topology-labeler.yaml`

**Step 2: Verify node labels**

Run:

```bash
kubectl get node rubik3 --show-labels
```

Expected: all three `rubikpi.ai/cpu-*` labels present.

**Step 3: Verify affinity from within a session pod**

Run:

```bash
./scripts/session.sh start verify-rubik3 --node rubik3 --cpu-type silver
kubectl exec session-verify-rubik3 -n sessions -- taskset -c 0-3 bash -lc 'taskset -p $$; grep Cpus_allowed_list /proc/self/status'
./scripts/session.sh stop verify-rubik3
```

Expected:

- session pod lands on `rubik3`
- affinity mask shows CPUs `0-3`

### Task 4: Run safety checks

**Files:**
- Modify: `install.sh`
- Modify: `manifests/cpu-topology-labeler.yaml`
- Test: `tests/cpu-topology-labeler.sh`

**Step 1: Run syntax and regression checks**

```bash
bash -n install.sh
bash tests/cpu-topology-labeler.sh
bash tests/session-coredns-regression.sh
```

Expected: PASS
