#!/usr/bin/env bash
# tests/e2e-vm-profile.sh — End-to-end per-repo VM profile build (issue #99, #105).
#
# Builds a tiny profile VM via the template's params and asserts that a declared apt
# repository was registered, an extra apt package layered, the fingerprint marker
# was stamped, and the libvirt-stack declaration granted the Lima user libvirt/kvm
# group membership (issue #137). This is a HOST-side script (it runs limactl),
# deliberately NOT named test_*.sh so run-tests.sh does not pipe it into a guest. It
# is invoked directly in CI and manages its own throwaway instance. The
# vagrant_plugins path is exercised by a real lab build, not here (installing
# vagrant + a native plugin is too heavy for CI).
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

# libvirt-daemon-system both exercises the package layer alongside cowsay and
# triggers the libvirt/kvm group-membership derivation (issue #137).
# Resolve the template's HOST_PROJECTS_DIR mount to an absolute path: limactl 2.1.1
# rejects a non-absolute mount location as fatal. This throwaway VM does not use
# /projects, so any valid absolute dir (the test tree here) satisfies the validator.
limactl create --name="${INSTANCE}" --tty=false \
  --set=".mounts[0].location = \"${HERE}\"" \
  --set=".param.APT_REPOS = \"${REPO}\"" \
  --set='.param.EXTRA_PACKAGES = "cowsay libvirt-daemon-system"' \
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

# 4. Declaring libvirt-daemon-system granted the Lima user libvirt/kvm group
#    membership (issue #137) — read from the user database, not the session.
groups_out="$(limactl shell "${INSTANCE}" -- bash -c 'id -nG "$(id -un)"')"
echo "${groups_out}" | tr ' ' '\n' | grep -qx libvirt \
  || fail "Lima user not in libvirt group (got: ${groups_out})"
echo "${groups_out}" | tr ' ' '\n' | grep -qx kvm \
  || fail "Lima user not in kvm group (got: ${groups_out})"

echo "PASS: vm profile end-to-end (apt_repo + package + fingerprint marker + libvirt/kvm groups)"
