# Bootstrap CLI Distribution Design

**Date:** 2026-03-11

**Goal:** Replace the current "clone repo and run `install.sh`" workflow with a GitHub-hosted bootstrap installer that gives users a stable `rubik-cluster` command and a two-command installation flow on Rubik Pi 3 boards.

## User Experience

Users should be able to set up any node with:

```bash
curl -fsSL https://raw.githubusercontent.com/<owner>/<repo>/<ref>/bootstrap/install.sh | sudo bash
sudo rubik-cluster install
```

The same two commands should work on:

- the first node, which bootstraps the cluster
- later nodes, which auto-join or repair

At the end of installation, the CLI should print the Rancher dashboard URL so users immediately see the result.

## Scope

This distribution path is only for Qualcomm Rubik Pi 3 boards.

That means:

- no architecture detection is required
- no multi-platform packaging is required
- no apt repo is required for the first iteration

## Recommended Architecture

Use a thin GitHub-hosted bootstrap script plus a Rubik-only release bundle.

### Bootstrap script

The bootstrap script is hosted directly in the GitHub repo and does only a few things:

1. Download a release bundle from GitHub Releases or another stable GitHub-hosted artifact URL.
2. Install a wrapper command at `/usr/local/bin/rubik-cluster`.
3. Extract the bundle into `/opt/rubik-cluster/releases/<version>`.
4. Point `/opt/rubik-cluster/current` at the extracted version.

The bootstrap script should stay small and stable. It should not contain the full cluster installation logic.

### Installed wrapper

The installed `rubik-cluster` wrapper should delegate into the currently active bundle under `/opt/rubik-cluster/current`.

Expected commands:

- `rubik-cluster install`
- `rubik-cluster version`
- `rubik-cluster update`
- `rubik-cluster doctor`
- `rubik-cluster session ...`
- `rubik-cluster bench`

## Bundle Contents

The release bundle should include the current operational assets needed for installation, sessions, and validation:

- `install.sh`
- `scripts/session.sh`
- `scripts/network-reconcile.sh`
- `scripts/cluster-discovery.sh`
- `manifests/`
- `benchmarks/build/hw_bench`
- `README.md`
- `INSTRUCTIONS.md`
- `VERSION`

This makes the installed product self-contained. Users do not need to clone the repo to install, start a session, or validate the hardware stack.

## Benchmark And Session UX

The installed CLI should treat session management and hardware validation as first-class features.

### Sessions

`rubik-cluster session ...` should wrap the existing session manager so users can:

- create a session pod
- connect to it
- stop it
- use CPU affinity flags such as `--cpu-type silver`

### Benchmark

The bundle should ship a prebuilt `hw_bench` binary so users can immediately validate hardware support without building anything locally.

`rubik-cluster bench` should either:

- run the bundled benchmark directly when appropriate, or
- print the exact command to run inside a session pod

## Rancher Output

At the end of `rubik-cluster install`, the CLI should always try to print the Rancher dashboard URL.

Behavior:

- init node: print Rancher URL and bootstrap password
- joined node: print joined-cluster success plus Rancher URL
- if Rancher is not ready yet: print a short "cluster joined; Rancher still initializing" message and the expected dashboard URL

## Release Model

Everything should be hosted on GitHub.

Recommended sources:

- bootstrap script from `raw.githubusercontent.com`
- versioned bundle from GitHub Releases

This avoids the need for a custom domain while still giving users a stable curl-based install path.

## Why This Approach

This approach is the best short-term balance because it:

- removes the repo-clone requirement
- preserves the current installer and operational scripts
- keeps hosting simple
- gives a product-like CLI immediately
- leaves a clean future migration path to an apt package if desired later
