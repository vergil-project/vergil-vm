# Guarantee buildkitd in the Lima VM for `nerdctl build`

- **Issue:** [#97](https://github.com/vergil-project/vergil-vm/issues/97)
- **Date:** 2026-06-02
- **Status:** Approved

## Goal

Guarantee `buildkitd` is installed and running in the vergil-agent Lima
VM so `nerdctl build` works on a freshly created VM with no manual setup.

## Background

vergil-docker's `docker/build.sh` now prefers `nerdctl` over `docker`
([vergil-docker#322](https://github.com/vergil-project/vergil-docker/issues/322)).
`nerdctl build` requires a reachable BuildKit backend. `build.sh` probes
for it and fails with a remediation message if absent, but the durable
fix is to provision buildkitd in the VM the ecosystem uses, so the
failure never happens in normal use.

## Root cause

The template already sets `containerd: { user: true }`, which makes Lima
pull the `nerdctl-full` bundle during its own provisioning. That bundle
**already ships** the `buildkitd` and `buildctl` binaries (at
`/usr/local/bin`) plus the helper
`/usr/local/bin/containerd-rootless-setuptool.sh`. The gap is not
installation — it is that nothing **starts** the buildkit daemon. So
`nerdctl build` has no backend to talk to.

The fix is therefore a provisioning step, not a package install.

## Approach

Use Lima's own mechanism — the same `containerd-rootless-setuptool.sh`
that set up rootless containerd — to install and start a rootless
buildkit systemd `--user` service. This is the canonical, upstream-blessed
path and avoids hand-rolling a unit that would drift from upstream
defaults.

`containerd-rootless-setuptool.sh install-buildkit`:

- Verifies `buildkitd` is on `PATH` and containerd is installed.
- Writes `~/.config/systemd/user/buildkit.service` configured for the
  rootless OCI worker
  (`--oci-worker=true --oci-worker-rootless=true --containerd-worker=false`).
- Enables and starts the unit.
- Exposes the socket at the default path nerdctl auto-probes
  (`$XDG_RUNTIME_DIR/buildkit-<namespace>/buildkitd.sock`), so
  `nerdctl build` needs no `--buildkit-host` flag or `BUILDKIT_HOST`.

User lingering is already enabled by Lima's containerd `install`, so the
buildkit `--user` unit survives logout and reboot.

The issue states a rootless containerd worker is acceptable; the rootless
OCI worker that `install-buildkit` configures satisfies this — it builds
images that `nerdctl` can load into the rootless containerd image store.

## Changes

### 1. `templates/agent.yaml` — provisioning step

Add a `mode: user` provisioning block after the existing user block:

```bash
#!/bin/bash
set -eux -o pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

# install-buildkit requires the rootless containerd user service to exist
# already (Lima provisions it via its own containerd setup). Wait for it
# rather than depend on provisioning-step ordering.
timeout 300 bash -c 'until systemctl --user is-active --quiet containerd; do sleep 3; done'

containerd-rootless-setuptool.sh install-buildkit
```

The `until systemctl --user is-active containerd` guard makes the step
robust to Lima provisioning order instead of assuming buildkit setup runs
after containerd setup.

### 2. `templates/agent.yaml` — readiness probe

Add `pgrep -f buildkitd` to the existing readiness until-loop, alongside
the current `pgrep -f containerd` check. This matches the probe's existing
style of using `pgrep` rather than `systemctl --user` (the probe shell has
no user-bus access). The VM will not report ready until buildkit is up.

### 3. `tests/test_services.sh`

Add `assert_active buildkit user` to the "Allowlist: load-bearing must be
up" section. The service-mask **denylist is untouched** — buildkit is a
new *user* unit and is not part of the issue-#78 reconciled system-unit
mask contract — so there is no drift between the test and the template's
minimization block.

### 4. `tests/test_containerd.sh`

After the existing pull-and-run checks, exercise a real build:

- Build a minimal image from an inline Dockerfile whose base is the
  already-pulled `ghcr.io/containerd/alpine:3.14.0` (no extra network
  dependency), with a trivial `RUN`.
- Assert the build succeeds.
- Remove the built image to leave the VM clean.

This proves the acceptance criterion (`nerdctl build` works out of the
box) end-to-end rather than only asserting the daemon is up.

## Out of scope

- No change to the service-minimization mask list, resource sizing, or
  `scripts/build.sh`.
- No `BUILDKIT_HOST` environment wiring — the default socket is what
  nerdctl probes.
- No host-side (`docker/build.sh`) changes; that lives in vergil-docker.

## Acceptance criteria

- The Lima template provisions and starts `buildkitd` (rootless OCI
  worker).
- A freshly created VM can run `nerdctl build` with no manual setup.
- The test suite asserts both the running buildkit `--user` service and a
  successful `nerdctl build`.

## Validation

```bash
vrg-container-run -- vrg-validate
```

Plus a full image build/test cycle:

```bash
./scripts/build.sh
```
