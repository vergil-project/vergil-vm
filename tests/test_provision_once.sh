#!/bin/bash
# tests/test_provision_once.sh — Assert first-boot provisioning ran to completion (issue #177).
#
# Auto-discovered by run-tests.sh; runs in-guest against a built VM. Lima
# re-runs every provisioning script on every boot (cloud-init per-boot
# runparts), so the network-bound install blocks are first-boot-only: each
# guards on a completion marker and skips once it exists, and stamps that
# marker as its LAST step — so a failed install never leaves the box marked
# provisioned. This test asserts the contract that those markers exist (the
# heavy blocks completed) and that the tools they install are actually present;
# a missing marker means a block either never finished or stopped stamping it.
set -euo pipefail

fail() { echo "test_provision_once: FAIL — $1" >&2; exit 1; }

# System-phase markers (root-owned, /etc/vergil).
for marker in /etc/vergil/provisioned.base /etc/vergil/provisioned.profile; do
    [ -f "$marker" ] || fail "$marker missing (a system-phase install block did not complete)"
done

# User-phase marker (the uv/rc-file step runs as the Lima user; /etc/vergil is
# root-owned, so its marker lives in the user's home).
[ -f "$HOME/.vergil/provisioned.uv" ] || fail "$HOME/.vergil/provisioned.uv missing (the user-phase install block did not complete)"

# The markers must reflect reality: the tools the gated blocks install are present.
for tool in gh node npm yq claude uv; do
    command -v "$tool" >/dev/null 2>&1 || fail "marker present but '$tool' is not installed"
done

echo "test_provision_once: all checks passed"
