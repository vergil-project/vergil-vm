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

echo "=== Build complete ==="
