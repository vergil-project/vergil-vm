#!/bin/bash
# tests/test_libvirt_groups.sh — Assert libvirt/kvm group membership matches the profile (issue #137).
#
# Auto-discovered by run-tests.sh; runs in-guest against a built VM. The
# group-membership provisioning step stamps /etc/vergil/libvirt-groups.requested
# with its derived decision: "true" when the profile declares the libvirt stack
# (libvirt-daemon-system in packages, vagrant-libvirt in vagrant_plugins, or
# nested = true), "false" otherwise. The contract is two-sided: requested ⇒ the
# Lima user is in both the libvirt group (gates the qemu:///system socket) and
# the kvm group (gates /dev/kvm), and not-requested ⇒ the user is in neither
# (the base box must not silently grow hypervisor access). Membership is read
# from the user database (`id -nG <user>`), not the current session, so the
# assertion holds regardless of login freshness.
set -euo pipefail

MARKER=/etc/vergil/libvirt-groups.requested

if [ ! -f "$MARKER" ]; then
    echo "test_libvirt_groups: FAIL — $MARKER missing (group-membership provisioning step did not run)" >&2
    exit 1
fi

requested="$(tr -d '[:space:]' < "$MARKER")"
user="$(id -un)"

in_group() { # in_group <group>
    id -nG "$user" | tr ' ' '\n' | grep -qx "$1"
}

case "$requested" in
true)
    if ! in_group libvirt; then
        echo "test_libvirt_groups: FAIL — libvirt stack requested but '$user' is not in the libvirt group" >&2
        exit 1
    fi
    if ! in_group kvm; then
        echo "test_libvirt_groups: FAIL — libvirt stack requested but '$user' is not in the kvm group" >&2
        exit 1
    fi
    ;;
false)
    if in_group libvirt; then
        echo "test_libvirt_groups: FAIL — libvirt stack not requested but '$user' is in the libvirt group" >&2
        exit 1
    fi
    if in_group kvm; then
        echo "test_libvirt_groups: FAIL — libvirt stack not requested but '$user' is in the kvm group" >&2
        exit 1
    fi
    ;;
*)
    echo "test_libvirt_groups: FAIL — unexpected marker value '$requested'" >&2
    exit 1
    ;;
esac

echo "test_libvirt_groups: all checks passed"
