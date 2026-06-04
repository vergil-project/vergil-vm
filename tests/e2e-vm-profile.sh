#!/usr/bin/env bash
# tests/e2e-vm-profile.sh — End-to-end per-repo VM profile build (issue #99).
#
# Builds a tiny profile VM via the template's params and asserts that the extra apt
# package layered, the provision hook ran, and the fingerprint marker was stamped.
# This is a HOST-side script (it runs limactl), deliberately NOT named test_*.sh so
# run-tests.sh does not try to pipe it into a guest. It is invoked directly in CI and
# manages its own throwaway instance.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="${HERE}/../templates/agent.yaml"
INSTANCE="vergil-profile-e2e"
WORK="$(mktemp -d)"
FP="testfp123"

cleanup() {
  limactl delete --force "${INSTANCE}" >/dev/null 2>&1 || true
  rm -rf "${WORK}"
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

# A trivial, self-contained provision hook (TOOLING only — here it just drops a sentinel).
mkdir -p "${WORK}/.vergil"
cat > "${WORK}/.vergil/provision.sh" <<'HOOK'
#!/bin/bash
set -eux
touch /tmp/vergil-hook-ran
HOOK

limactl create --name="${INSTANCE}" --tty=false \
  --set=".mounts[0].location = \"${WORK}\"" \
  --set=".mounts[0].mountPoint = \"${WORK}\"" \
  --set='.param.EXTRA_PACKAGES = "cowsay"' \
  --set=".param.PROVISION_HOOK = \"${WORK}/.vergil/provision.sh\"" \
  --set=".param.SPEC_FINGERPRINT = \"${FP}\"" \
  "${TEMPLATE}"
limactl start "${INSTANCE}" --tty=false

# 1. The extra package layered (the base image does not ship cowsay).
limactl shell "${INSTANCE}" -- bash -lc 'command -v cowsay' >/dev/null \
  || fail "extra package 'cowsay' not installed"

# 2. The provision hook ran.
limactl shell "${INSTANCE}" -- test -f /tmp/vergil-hook-ran \
  || fail "provision hook did not run (sentinel missing)"

# 3. The fingerprint marker was stamped with the injected value.
got="$(limactl shell "${INSTANCE}" -- cat /etc/vergil/vm-spec.fingerprint | tr -d '[:space:]')"
[ "${got}" = "${FP}" ] || fail "fingerprint marker is '${got}', expected '${FP}'"

echo "PASS: vm profile end-to-end (package + hook + fingerprint marker)"
