#!/bin/bash
# tests/test_port_forwards.sh — Assert port-forward relay state matches the
# build request (issue #170).
#
# Auto-discovered by run-tests.sh; runs in-guest against a built VM. The
# port-forward provisioning step stamps /etc/vergil/port-forwards.requested
# with the count of declared forwards ("0" on the base build) and creates one
# socket-activated systemd-socket-proxyd relay per entry. The contract is
# two-sided: the number of vergil-portforward-*.socket units must equal the
# declared count, and on the base build (count 0) the box must grow NO relay
# surface. A mismatch is a wiring bug. The full host-reachability path (declare
# a forward, build, reach a test listener through Lima's auto-forward) is
# covered by the standalone tests/e2e-port-forwards.sh.
set -euo pipefail

MARKER=/etc/vergil/port-forwards.requested

if [ ! -f "$MARKER" ]; then
    echo "test_port_forwards: FAIL — $MARKER missing (port-forward provisioning step did not run)" >&2
    exit 1
fi

requested="$(tr -d '[:space:]' < "$MARKER")"

if ! printf '%s' "$requested" | grep -qE '^[0-9]+$'; then
    echo "test_port_forwards: FAIL — unexpected marker value '$requested'" >&2
    exit 1
fi

# Count the relay socket units the provisioning step actually wrote.
units=0
for u in /etc/systemd/system/vergil-portforward-*.socket; do
    [ -e "$u" ] || continue
    units=$((units + 1))
done

if [ "$units" -ne "$requested" ]; then
    echo "test_port_forwards: FAIL — $requested forward(s) declared but $units relay socket unit(s) present" >&2
    exit 1
fi

echo "test_port_forwards: all checks passed ($requested forward(s) declared)"
