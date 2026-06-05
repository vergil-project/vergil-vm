#!/bin/bash
# tests/test_nested_virt.sh — Assert nested-virt state matches the build request (issue #131).
#
# Auto-discovered by run-tests.sh; runs in-guest against a built VM. The
# nested-virt provisioning step stamps /etc/vergil/nested-virt.requested with
# the NESTED_VIRT param ("false" on the base build). The contract is
# two-sided: requested ⇒ /dev/kvm present (KVM-accelerated nested guests
# possible), and not-requested ⇒ /dev/kvm absent (the base box must not
# silently grow a hypervisor surface). A mismatch in either direction is a
# wiring bug — tooling set only one half of the nestedVirtualization /
# NESTED_VIRT pair, or the template default drifted.
set -euo pipefail

MARKER=/etc/vergil/nested-virt.requested

if [ ! -f "$MARKER" ]; then
    echo "test_nested_virt: FAIL — $MARKER missing (nested-virt provisioning step did not run)" >&2
    exit 1
fi

requested="$(tr -d '[:space:]' < "$MARKER")"

case "$requested" in
true)
    if [ ! -c /dev/kvm ]; then
        echo "test_nested_virt: FAIL — nested virt requested but /dev/kvm absent" >&2
        exit 1
    fi
    ;;
false)
    if [ -c /dev/kvm ]; then
        echo "test_nested_virt: FAIL — nested virt not requested but /dev/kvm present" >&2
        exit 1
    fi
    ;;
*)
    echo "test_nested_virt: FAIL — unexpected marker value '$requested'" >&2
    exit 1
    ;;
esac

echo "test_nested_virt: all checks passed"
