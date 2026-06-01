#!/bin/bash
# tests/run-tests.sh — Run all test scripts inside a Lima VM.
# Usage: ./tests/run-tests.sh [instance-name]
set -euo pipefail

INSTANCE="${1:-vergil-agent}"
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
failures=0
total=0

# `limactl shell` pipes a non-login shell that never establishes
# XDG_RUNTIME_DIR, so in-guest `systemctl --user` can't reach the user bus
# ("Failed to connect to bus: No medium found"). Export it before exec'ing
# the test so user-service assertions (rootless containerd) work.
run_in_guest() { # run_in_guest <test-file>
    limactl shell "$INSTANCE" -- \
        bash -c 'export XDG_RUNTIME_DIR=/run/user/$(id -u); exec bash -s' < "$1"
}

for test in "${TESTS_DIR}"/test_*.sh; do
    name="$(basename "$test")"
    total=$((total + 1))
    printf "  %-30s " "${name}"
    if run_in_guest "$test" > /dev/null 2>&1; then
        echo "PASS"
    else
        echo "FAIL"
        echo "    Re-running with output:"
        # `|| true`: the re-run intentionally re-executes a failing test for
        # diagnostics; with `set -e -o pipefail` its non-zero exit would
        # otherwise abort the runner before the remaining tests run.
        run_in_guest "$test" 2>&1 | sed 's/^/    /' || true
        failures=$((failures + 1))
    fi
done

echo ""
echo "${total} tests, ${failures} failures"
exit "${failures}"
