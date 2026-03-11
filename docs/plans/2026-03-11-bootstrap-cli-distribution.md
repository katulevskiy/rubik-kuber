# Bootstrap CLI Distribution Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Replace the repo-clone workflow with a GitHub-hosted bootstrap installer that installs a stable `rubik-cluster` CLI, bundles the current installer/session tooling, ships a prebuilt `hw_bench`, and prints the Rancher dashboard URL after install.

**Architecture:** A small bootstrap script hosted in the GitHub repo installs a wrapper command and downloads a Rubik-only versioned release bundle from GitHub. The wrapper delegates to `/opt/rubik-cluster/current`, where the existing installer, scripts, manifests, docs, and benchmark binary live.

**Tech Stack:** Bash, GitHub raw content, GitHub Releases, tarball packaging, existing `install.sh`, existing session tooling, prebuilt `hw_bench`

---

### Task 1: Add bundle layout and release metadata

**Files:**
- Create: `bootstrap/install.sh`
- Create: `bootstrap/rubik-cluster`
- Create: `VERSION`
- Create: packaging helper files/scripts as needed
- Modify: repo layout references if needed

**Step 1: Write the failing test**

Add a shell regression that asserts:

- bootstrap installer exists
- wrapper exists
- `VERSION` exists
- wrapper references `/opt/rubik-cluster/current`

**Step 2: Run test to verify it fails**

Run:

```bash
bash tests/bootstrap-cli-distribution.sh
```

Expected: FAIL because the bootstrap assets do not exist yet.

**Step 3: Write minimal implementation**

Create:

- a bootstrap installer script
- a stable wrapper script
- a version file

Keep the wrapper small and focused on dispatch.

**Step 4: Run test to verify it passes**

Run:

```bash
bash tests/bootstrap-cli-distribution.sh
```

Expected: PASS

### Task 2: Implement the GitHub-hosted bootstrap installer

**Files:**
- Create: `bootstrap/install.sh`
- Modify: tests from Task 1

**Step 1: Write the failing test**

Assert the bootstrap script:

- installs to `/usr/local/bin/rubik-cluster`
- uses `/opt/rubik-cluster/releases/<version>`
- updates `/opt/rubik-cluster/current`
- downloads a GitHub-hosted bundle rather than cloning the repo

**Step 2: Run test to verify it fails**

Run:

```bash
bash tests/bootstrap-cli-distribution.sh
```

Expected: FAIL before logic is implemented.

**Step 3: Write minimal implementation**

Implement bootstrap behavior:

- create install directories
- download bundle tarball
- extract versioned release
- update current symlink
- install wrapper

Support a configurable GitHub release URL so local testing and future release automation are possible.

**Step 4: Run test to verify it passes**

Run:

```bash
bash tests/bootstrap-cli-distribution.sh
```

Expected: PASS

### Task 3: Implement the installed `rubik-cluster` wrapper UX

**Files:**
- Create: `bootstrap/rubik-cluster`
- Possibly create: wrapper helper scripts inside the bundle
- Test: `tests/bootstrap-cli-distribution.sh`

**Step 1: Write the failing test**

Assert the wrapper exposes or dispatches:

- `install`
- `version`
- `update`
- `doctor`
- `session`
- `bench`

**Step 2: Run test to verify it fails**

Run:

```bash
bash tests/bootstrap-cli-distribution.sh
```

Expected: FAIL

**Step 3: Write minimal implementation**

Implement wrapper commands:

- `install` delegates to bundled installer
- `session` delegates to bundled `scripts/session.sh`
- `bench` runs or prints the bundled `benchmarks/build/hw_bench`
- `version` reads `VERSION`
- `update` re-runs bundle acquisition logic
- `doctor` performs basic environment checks

**Step 4: Run test to verify it passes**

Run:

```bash
bash tests/bootstrap-cli-distribution.sh
```

Expected: PASS

### Task 4: Bundle benchmark and session tooling as first-class installed assets

**Files:**
- Modify: bundle assembly scripts/config
- Modify: wrapper
- Test: `tests/bootstrap-cli-distribution.sh`

**Step 1: Write the failing test**

Assert the bundle includes:

- `scripts/session.sh`
- `benchmarks/build/hw_bench`

Assert the wrapper references both.

**Step 2: Run test to verify it fails**

Run:

```bash
bash tests/bootstrap-cli-distribution.sh
```

Expected: FAIL before bundle references are wired in.

**Step 3: Write minimal implementation**

Make sure:

- session commands work via the wrapper without a repo checkout
- the prebuilt benchmark ships in the installed bundle

**Step 4: Run test to verify it passes**

Run:

```bash
bash tests/bootstrap-cli-distribution.sh
```

Expected: PASS

### Task 5: Print Rancher URL from the installed CLI

**Files:**
- Modify: wrapper or bundled installer entrypoint
- Modify: docs if needed
- Test: `tests/bootstrap-cli-distribution.sh`

**Step 1: Write the failing test**

Assert the installed CLI includes behavior or messaging that surfaces the Rancher dashboard URL after installation.

**Step 2: Run test to verify it fails**

Run:

```bash
bash tests/bootstrap-cli-distribution.sh
```

Expected: FAIL

**Step 3: Write minimal implementation**

Ensure:

- init node prints Rancher URL and password
- later nodes print cluster-joined success plus Rancher URL when available

Use current cluster state where possible rather than static assumptions.

**Step 4: Run test to verify it passes**

Run:

```bash
bash tests/bootstrap-cli-distribution.sh
```

Expected: PASS

### Task 6: Document the new install path

**Files:**
- Modify: `README.md`
- Modify: `INSTRUCTIONS.md`

**Step 1: Write the failing test**

Extend the distribution regression to require the two-command bootstrap flow in docs.

**Step 2: Run test to verify it fails**

Run:

```bash
bash tests/bootstrap-cli-distribution.sh
```

Expected: FAIL before docs are updated.

**Step 3: Write minimal implementation**

Document:

- GitHub-hosted bootstrap command
- `sudo rubik-cluster install`
- session commands
- benchmark command
- Rancher result output

**Step 4: Run test to verify it passes**

Run:

```bash
bash tests/bootstrap-cli-distribution.sh
```

Expected: PASS

### Task 7: Verify locally

**Files:**
- Test: bootstrap/wrapper files and docs

**Step 1: Run syntax checks**

```bash
bash -n bootstrap/install.sh
bash -n bootstrap/rubik-cluster
```

Expected: exit code 0

**Step 2: Run regressions**

```bash
bash tests/bootstrap-cli-distribution.sh
```

Expected: PASS

**Step 3: Smoke-test bootstrap in a safe local target directory**

Run the bootstrap against a temporary prefix or staging directory so it can be validated without mutating the real install path first.

Expected:

- wrapper installed
- bundle extracted
- commands resolve correctly
