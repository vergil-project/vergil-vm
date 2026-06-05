#!/usr/bin/env bash
# tests/e2e-nested-virt.sh — End-to-end nested-virtualization build (issue #131).
#
# Builds a throwaway VM with nested virtualization enabled exactly the way
# vrg-vm does for a profile that declares `nested = true`: the top-level Lima
# `nestedVirtualization` flag plus the NESTED_VIRT param, set together.
# Asserts /dev/kvm exists in the guest. This is a HOST-side script (it runs
# limactl), deliberately NOT named test_*.sh so run-tests.sh does not pipe it
# into a guest. Requires a nested-virt-capable host — macOS 15+ on M3-or-later
# Apple silicon; on anything older the create/start fails, and the messages
# below say why instead of leaving a bare stack of Lima errors.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="${HERE}/../templates/agent.yaml"
INSTANCE="vergil-nested-e2e"

cleanup() {
  limactl delete --force "${INSTANCE}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

limactl create --name="${INSTANCE}" --tty=false \
  --set='.nestedVirtualization = true' \
  --set='.param.NESTED_VIRT = "true"' \
  "${TEMPLATE}" \
  || fail "create failed — host may not support nested virtualization (requires macOS 15+ on M3-or-later Apple silicon)"
limactl start "${INSTANCE}" --tty=false \
  || fail "start failed — host may not support nested virtualization (requires macOS 15+ on M3-or-later Apple silicon)"

# /dev/kvm is the whole point: present, and a character device.
limactl shell "${INSTANCE}" -- test -c /dev/kvm \
  || fail "/dev/kvm absent in nested-virt guest"

echo "PASS: nested virtualization end-to-end (/dev/kvm present)"
