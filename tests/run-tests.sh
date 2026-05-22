#!/bin/bash
# tests/run-tests.sh — Run all test scripts inside a Lima VM.
# Usage: ./tests/run-tests.sh [instance-name]
set -euo pipefail

INSTANCE="${1:-vergil-agent}"
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
failures=0
total=0

for test in "${TESTS_DIR}"/test_*.sh; do
    name="$(basename "$test")"
    total=$((total + 1))
    printf "  %-30s " "${name}"
    if limactl shell "$INSTANCE" -- bash -s < "$test" > /dev/null 2>&1; then
        echo "PASS"
    else
        echo "FAIL"
        echo "    Re-running with output:"
        limactl shell "$INSTANCE" -- bash -s < "$test" 2>&1 | sed 's/^/    /'
        failures=$((failures + 1))
    fi
done

echo ""
echo "${total} tests, ${failures} failures"
exit "${failures}"
