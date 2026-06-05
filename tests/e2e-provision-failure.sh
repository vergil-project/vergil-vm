#!/usr/bin/env bash
# tests/e2e-provision-failure.sh — Provisioning failures fail the start, loudly (issue #130).
#
# Builds a throwaway VM whose extra-package layer declares a deliberately
# uninstallable package and asserts the failure contract: `limactl start`
# exits non-zero (the readiness probe gates on clean cloud-init completion),
# and /etc/vergil/provision-error names the offending package — a one-line
# error instead of a forensic dig through cloud-init logs. This is a HOST-side
# script (it runs limactl), deliberately NOT named test_*.sh so run-tests.sh
# does not pipe it into a guest. The start spends its full --timeout before
# failing (Lima retries probes until the deadline), so this is the slowest
# step in build.sh — that is the price of testing the negative path for real.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="${HERE}/../templates/agent.yaml"
INSTANCE="vergil-provfail-e2e"
BOGUS="vergil-no-such-package-e2e"

cleanup() {
  limactl delete --force "${INSTANCE}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

limactl create --name="${INSTANCE}" --tty=false \
  --set=".param.EXTRA_PACKAGES = \"${BOGUS}\"" \
  "${TEMPLATE}"

# The start MUST fail: the probe never sees a clean cloud-init "done" because
# the per-package candidate check aborts the profile layer.
if limactl start "${INSTANCE}" --tty=false --timeout=15m; then
  fail "limactl start succeeded despite an uninstallable extra package — provisioning failure was silent"
fi

# The failure is named: provision-error identifies the exact package. The VM
# itself is still running (only the readiness gate failed), so shell works.
limactl shell "${INSTANCE}" -- grep -q "${BOGUS}" /etc/vergil/provision-error \
  || fail "/etc/vergil/provision-error missing or does not name '${BOGUS}'"

echo "PASS: provisioning failure is loud (start fails, provision-error names the package)"
