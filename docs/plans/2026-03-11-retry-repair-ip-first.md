# Retry And IP-First Repair Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Make joined-node repair IP-first by default and add `--retry` so broken nodes can rediscover and recover from stale local join endpoints automatically.

**Architecture:** Keep fresh auto-join behavior unchanged, but refactor joined-node repair so it can optionally refresh `server:` and `token:` from LAN discovery before rewriting config. Add a CLI flag that forces rediscovery and fails closed when discovery is not sufficient.

**Tech Stack:** Bash, RKE2, Avahi/mDNS discovery, systemd, shell regression tests

---

### Task 1: Add failing regression coverage for retry/repair endpoint resolution

**Files:**
- Create: `tests/install-repair-retry.sh`
- Modify: `tests/install-progress-ui.sh`
- Test: `install.sh`

**Step 1: Write the failing test**

Cover these behaviors:

- joined-node repair refreshes stale hostname `server:` values from discovery
- joined-node repair preserves existing token when discovery is `manual`
- `--retry` is parsed and sets a retry flag

**Step 2: Run test to verify it fails**

Run:

```bash
bash tests/install-repair-retry.sh
```

Expected before implementation: failure because the helper/flag behavior does not exist yet.

**Step 3: Write minimal implementation**

Add testable helper functions in `install.sh` instead of embedding logic directly in `main()`.

**Step 4: Run test to verify it passes**

Run:

```bash
bash tests/install-repair-retry.sh
```

Expected: PASS

### Task 2: Add CLI parsing and retry-aware joined-node repair

**Files:**
- Modify: `install.sh`
- Test: `tests/install-repair-retry.sh`

**Step 1: Write the failing test**

Use the same shell regression to assert:

- `--retry` is accepted
- unknown flags are rejected
- joined-node repair can refresh endpoint state from discovery without needing `.local`

**Step 2: Run test to verify it fails**

Run:

```bash
bash tests/install-repair-retry.sh
```

Expected: FAIL due to missing CLI parsing and repair helper behavior.

**Step 3: Write minimal implementation**

- Add `parse_cli_args`
- add a retry state variable
- add a non-fatal discovery helper for repair
- add a retry-aware joined-node endpoint resolver
- restart `rke2-agent` / `rke2-server` after rewriting join config so refreshed endpoints actually take effect

**Step 4: Run test to verify it passes**

Run:

```bash
bash tests/install-repair-retry.sh
bash tests/discovery-uses-ip-endpoint.sh
```

Expected: PASS

### Task 3: Document retry mode and IP-first repair

**Files:**
- Modify: `README.md`
- Modify: `INSTRUCTIONS.md`

**Step 1: Write the failing test**

Extend an existing documentation regression or add string assertions that require:

- `--retry` to be documented
- repair behavior to mention rediscovery / IP-first refresh

**Step 2: Run test to verify it fails**

Run:

```bash
bash tests/install-progress-ui.sh
```

Expected: FAIL before docs are updated.

**Step 3: Write minimal implementation**

Document:

- `sudo ./install.sh --retry`
- that standard repair tries to refresh joined-node endpoint state from discovery
- that discovery prefers the current advertised IP

**Step 4: Run test to verify it passes**

Run:

```bash
bash tests/install-progress-ui.sh
```

Expected: PASS

### Task 4: Verify full installer safety

**Files:**
- Modify: `install.sh`
- Test: `tests/*.sh`

**Step 1: Run syntax checks**

```bash
bash -n install.sh
bash -n tests/install-repair-retry.sh
```

Expected: exit code 0

**Step 2: Run targeted regressions**

```bash
bash tests/install-repair-retry.sh
bash tests/discovery-uses-ip-endpoint.sh
bash tests/install-progress-ui.sh
bash tests/install-hw-stack-parity.sh
```

Expected: all PASS
