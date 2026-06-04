#!/usr/bin/env bash
# tests/e2e-vm-profile.sh — End-to-end per-repo VM profile build (issue #99, #105).
#
# Builds a tiny profile VM via the template's params and asserts that a declared apt
# repository was registered, an extra apt package layered, and the fingerprint marker
# was stamped. This is a HOST-side script (it runs limactl), deliberately NOT named
# test_*.sh so run-tests.sh does not pipe it into a guest. It is invoked directly in CI
# and manages its own throwaway instance. The vagrant_plugins path is exercised by a
# real lab build, not here (installing vagrant + a native plugin is too heavy for CI).
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="${HERE}/../templates/agent.yaml"
INSTANCE="vergil-profile-e2e"
FP="testfp123"
REPO="hashicorp|https://apt.releases.hashicorp.com/gpg|https://apt.releases.hashicorp.com|noble|main"

cleanup() {
  limactl delete --force "${INSTANCE}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

limactl create --name="${INSTANCE}" --tty=false \
  --set=".param.APT_REPOS = \"${REPO}\"" \
  --set='.param.EXTRA_PACKAGES = "cowsay"' \
  --set=".param.SPEC_FINGERPRINT = \"${FP}\"" \
  "${TEMPLATE}"
limactl start "${INSTANCE}" --tty=false

# 1. The declared apt repository was registered (key + signed source list).
limactl shell "${INSTANCE}" -- test -f /usr/share/keyrings/hashicorp.gpg \
  || fail "apt_repos key not registered (keyring missing)"
limactl shell "${INSTANCE}" -- grep -q "apt.releases.hashicorp.com" \
  /etc/apt/sources.list.d/hashicorp.list \
  || fail "apt_repos source list not written"

# 2. The extra apt package layered (the base image does not ship cowsay).
limactl shell "${INSTANCE}" -- bash -lc 'command -v cowsay' >/dev/null \
  || fail "extra package 'cowsay' not installed"

# 3. The fingerprint marker was stamped with the injected value.
got="$(limactl shell "${INSTANCE}" -- cat /etc/vergil/vm-spec.fingerprint | tr -d '[:space:]')"
[ "${got}" = "${FP}" ] || fail "fingerprint marker is '${got}', expected '${FP}'"

echo "PASS: vm profile end-to-end (apt_repo + package + fingerprint marker)"
