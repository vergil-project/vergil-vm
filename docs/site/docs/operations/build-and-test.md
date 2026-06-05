# Build and Test

## How It Works

The build script (`scripts/build.sh`) validates the VM template,
creates a temporary VM, runs the full test suite inside it, and cleans
up:

```text
build.sh
  ├─ Validate template syntax (limactl validate)
  ├─ Delete any previous test VM
  ├─ Create VM from template (name: vergil-agent-test)
  │   └─ Mount: repo root with path preservation
  ├─ Start VM (wait for readiness probe, up to 30 min)
  ├─ Run test suite (tests/run-tests.sh)
  │   └─ Execute each test_*.sh inside VM via limactl shell
  └─ Cleanup: stop and delete VM
```

## Running Locally

Build, test, and clean up:

```bash
./scripts/build.sh
```

Build and test, but keep the VM running for debugging:

```bash
./scripts/build.sh --keep
```

When using `--keep`, the VM remains available after tests complete:

```bash
limactl shell vergil-agent-test
```

## Test Suite

All tests run inside the VM via `limactl shell`. The test runner
(`tests/run-tests.sh`) automatically discovers and executes every
`test_*.sh` file in the `tests/` directory.

| Test | Verifies |
| ---- | -------- |
| `test_base.sh` | Ubuntu 24.04, zsh default shell, passwordless sudo |
| `test_containerd.sh` | Rootless containerd running, nerdctl can pull and run containers |
| `test_credentials.sh` | Credential files exist with correct permissions, git HTTPS config |
| `test_nested_virt.sh` | `/dev/kvm` presence matches the `NESTED_VIRT` build request, in both directions |
| `test_services.sh` | Service-surface minimization: the mask list is applied, snapd and unattended-upgrades are purged |
| `test_ssh.sh` | sshd accepts `COLORTERM`, `TERM_PROGRAM`, `TERM_PROGRAM_VERSION` |
| `test_tools.sh` | All development tools installed (git, gh, uv, node, claude, jq, yq, rg, fzf) |
| `test_vergil.sh` | vergil-tooling installs via uv, `vrg-*` commands resolve on PATH |
| `test_vm_profile.sh` | Per-repo profile provisioning ran (spec-fingerprint marker stamped) |

Failed tests are automatically re-run with output displayed for
debugging. The runner reports a summary at the end:

```text
6 tests, 0 failures
```

## End-to-End Scripts

Two host-side scripts (they run `limactl`, so they are deliberately not
named `test_*.sh`) build their own throwaway, parameterized instances.
`build.sh` runs both after the in-guest suite:

| Script | Verifies |
| ------ | -------- |
| `e2e-vm-profile.sh` | Per-repo profile params end-to-end: apt repo registered, extra package layered, fingerprint stamped |
| `e2e-nested-virt.sh` | Nested virtualization end-to-end: `nestedVirtualization` + `NESTED_VIRT` set together yields `/dev/kvm` in the guest (requires macOS 15+ on M3-or-later Apple silicon) |

## Adding a New Test

Create a new file matching the `test_*.sh` pattern in `tests/`:

```bash
#!/bin/bash
set -euo pipefail

# Verify something specific about the VM
command -v my-tool >/dev/null 2>&1 || { echo "my-tool not found"; exit 1; }
```

The test runner picks it up automatically on the next build — no
registration or configuration needed. Tests run inside the VM, so they
have access to all provisioned tools and the projects mount.
