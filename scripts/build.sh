#!/bin/bash
# scripts/build.sh — Build and test the vergil-agent VM image.
#
# Creates a temporary Lima VM from the agent template, runs
# the full test suite inside it, and cleans up.
#
# Usage:
#   ./scripts/build.sh              # Build, test, clean up
#   ./scripts/build.sh --keep       # Build, test, keep the VM running
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
INSTANCE="vergil-agent-test"
TEMPLATE="${REPO_ROOT}/templates/agent.yaml"
TESTS="${REPO_ROOT}/tests/run-tests.sh"
KEEP=false

for arg in "$@"; do
    case "$arg" in
        --keep) KEEP=true ;;
        *) echo "Unknown argument: $arg" >&2; exit 1 ;;
    esac
done

cleanup() {
    if [ "$KEEP" = false ]; then
        echo "Cleaning up..."
        limactl stop "$INSTANCE" 2>/dev/null || true
        limactl delete --force "$INSTANCE" 2>/dev/null || true
    else
        echo "VM kept running: limactl shell $INSTANCE"
    fi
}
trap cleanup EXIT

# agent.yaml is generated from the skeleton + provision scripts. Fail early if
# the committed copy is stale, so we never build/test an out-of-date template.
echo "=== Checking templates/agent.yaml is up to date ==="
"${REPO_ROOT}/scripts/build-template.sh" --check
echo ""

echo "=== Building vergil-agent VM ==="
echo "Instance: $INSTANCE"
echo "Template: $TEMPLATE"
echo ""

# No standalone `limactl validate` here: the template carries a
# HOST_PROJECTS_DIR placeholder that is only resolved by the --set override
# below, and `limactl validate` has no --set. `limactl create` validates the
# effective merged config, so the early check is redundant, not lost.

# Delete any previous test instance
limactl stop "$INSTANCE" 2>/dev/null || true
limactl delete --force "$INSTANCE" 2>/dev/null || true

# Create and start the VM (non-interactive)
echo "Creating VM..."
limactl create --name="$INSTANCE" "$TEMPLATE" --tty=false \
    --set=".mounts[0].location = \"${REPO_ROOT}\""
echo "Starting VM..."
limactl start "$INSTANCE" --tty=false --timeout=30m
echo "VM started."
echo ""

# Run tests
echo "=== Running tests ==="
bash "$TESTS" "$INSTANCE"
echo ""

# Per-repo VM profile end-to-end (issue #99): builds its own throwaway
# parameterized instance to verify package layering + provision hook + fingerprint.
echo "=== Running per-repo VM profile e2e ==="
bash "${REPO_ROOT}/tests/e2e-vm-profile.sh"
echo ""

# Port-forward relay end-to-end (issue #170): builds its own throwaway instance
# declaring a port_forwards entry to an in-VM test listener and asserts the
# relay binds 0.0.0.0 and the Mac's localhost reaches it via Lima auto-forward.
echo "=== Running port-forward relay e2e ==="
bash "${REPO_ROOT}/tests/e2e-port-forwards.sh"
echo ""

# Nested-virtualization end-to-end (issue #131): builds its own throwaway
# instance with nestedVirtualization enabled and asserts /dev/kvm appears.
# Requires macOS 15+ on M3-or-later Apple silicon; fails loudly otherwise.
echo "=== Running nested-virtualization e2e ==="
bash "${REPO_ROOT}/tests/e2e-nested-virt.sh"
echo ""

# Provisioning-failure end-to-end (issue #130): builds its own throwaway
# instance with an uninstallable extra package and asserts the start fails
# with the package named in /etc/vergil/provision-error. Slowest step — the
# failing start spends its full timeout before Lima gives up.
echo "=== Running provisioning-failure e2e ==="
bash "${REPO_ROOT}/tests/e2e-provision-failure.sh"
echo ""

echo "=== Build complete ==="
