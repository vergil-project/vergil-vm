#!/usr/bin/env bash
# tests/check-rootless-userns.sh — Assert the generated gcp vm cloud-init.yaml relaxes
# kernel.apparmor_restrict_unprivileged_userns BEFORE the rootless containerd install.
# Ubuntu 24.04 defaults that sysctl to 1, which blocks the unprivileged user namespaces
# RootlessKit needs; without this, setup-containerd.sh's `containerd-rootless-setuptool.sh
# install` fails ("fork/exec /proc/self/exe: permission denied") and 35-buildkit.sh then
# times out waiting for the user service, failing the whole provision. (#251)
# HOST-side, no tofu. check-* prefix keeps it out of the run-tests.sh in-guest glob.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
CLOUD_INIT="${ROOT}/opentofu/modules/gcp/vm/cloud-init.yaml"

sysctl_line="$(grep -n 'apparmor_restrict_unprivileged_userns[[:space:]]*=[[:space:]]*0' \
  "${CLOUD_INIT}" | head -1 | cut -d: -f1 || true)"
install_line="$(grep -n 'containerd-rootless-setuptool.sh install' \
  "${CLOUD_INIT}" | head -1 | cut -d: -f1 || true)"

if [ -z "${install_line}" ]; then
  echo "FAIL: cloud-init.yaml has no rootless containerd install step to guard" >&2
  exit 1
fi
if [ -z "${sysctl_line}" ]; then
  echo "FAIL: cloud-init.yaml does not disable kernel.apparmor_restrict_unprivileged_userns" >&2
  echo "      — rootless containerd will fail to start on Ubuntu 24.04 (#251)" >&2
  exit 1
fi
if [ "${sysctl_line}" -ge "${install_line}" ]; then
  echo "FAIL: the userns sysctl (line ${sysctl_line}) must precede the rootless" >&2
  echo "      containerd install (line ${install_line}) in cloud-init.yaml (#251)" >&2
  exit 1
fi
echo "PASS: cloud-init.yaml relaxes apparmor_restrict_unprivileged_userns before the rootless install"
