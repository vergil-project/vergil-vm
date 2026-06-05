#!/bin/bash
# tests/test_vm_profile.sh — Assert the per-repo VM profile provisioning ran (issue #99).
#
# Auto-discovered by run-tests.sh; runs in-guest against a built VM. On the base
# build the profile-layering provisioning step runs with empty params, so apt repos,
# packages, and vagrant plugins are skipped — but the step ALWAYS stamps the
# spec-fingerprint marker. Its presence therefore proves the provisioning block executed
# and is wired correctly. The full param path (apt_repos + package install + fingerprint
# value) is covered by the standalone tests/e2e-vm-profile.sh, which builds a parameterized VM.
set -euo pipefail

MARKER=/etc/vergil/vm-spec.fingerprint

if [ ! -f "$MARKER" ]; then
    echo "test_vm_profile: FAIL — $MARKER missing (profile provisioning step did not run)" >&2
    exit 1
fi

# A successful build must not have recorded a provisioning failure (issue
# #130): provisioning steps tee fatal errors into this marker, and the
# readiness probe fails the start on its presence — so on a box that reached
# the test suite it must be absent.
if [ -f /etc/vergil/provision-error ]; then
    echo "test_vm_profile: FAIL — /etc/vergil/provision-error present: $(cat /etc/vergil/provision-error)" >&2
    exit 1
fi

echo "test_vm_profile: all checks passed"
