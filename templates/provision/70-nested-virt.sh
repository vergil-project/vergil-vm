#!/bin/bash
set -eux -o pipefail
NESTED="{{.Param.NESTED_VIRT}}"
mkdir -p /etc/vergil
printf '%s\n' "${NESTED:-false}" > /etc/vergil/nested-virt.requested
if [ "${NESTED}" = "true" ] && [ ! -c /dev/kvm ]; then
  # tee into provision-error so the failure is named at the start
  # boundary (issue #130), not just buried in the cloud-init log.
  printf '%s\n' \
    "ERROR: nested virtualization was requested (NESTED_VIRT=true) but" \
    "/dev/kvm is absent in the guest. The host must be macOS 15+ on" \
    "M3-or-later Apple silicon, and the instance must be created with" \
    "nestedVirtualization=true (vrg-vm sets both halves together)." \
    | tee /etc/vergil/provision-error >&2
  exit 1
fi
