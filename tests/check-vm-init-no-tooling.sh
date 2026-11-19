#!/usr/bin/env bash
# tests/check-vm-init-no-tooling.sh — Assert scripts/vrg-vm-init.sh installs no
# vergil-tooling: `vrg-vm create` installs it in its `tooling` stage, so a second
# install here would be a duplicate (epic vergil-project/.github#1350, spec §4.5).
# The script still injects the credentials, configures git and runs the verification,
# and it no longer reads vergil.toml, so it runs with none beside it.
# Hermetic: `limactl` is a stub on PATH that records its argv.
# HOST-side. check-* prefix keeps it out of the run-tests.sh in-guest glob.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

if grep -nE 'uv tool install|vergil-tooling *@|VERGIL_SERIES' "${ROOT}/scripts/vrg-vm-init.sh"; then
  fail "scripts/vrg-vm-init.sh still installs vergil-tooling or reads its series"
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/repo/scripts"
# shellcheck disable=SC2016  # literal stub-script text; expands when the stub runs
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >> "${LIMACTL_LOG}"' \
  'cat > /dev/null' \
  > "$tmp/bin/limactl"
chmod +x "$tmp/bin/limactl"
: > "$tmp/app.pem"
# A copy of the scripts with no vergil.toml beside them.
cp "${ROOT}/scripts/vrg-vm-init.sh" "${ROOT}/scripts/vm-verify-credentials.sh" "$tmp/repo/scripts/"

export LIMACTL_LOG="$tmp/limactl.log"
: > "$LIMACTL_LOG"
init_rc=0
PATH="$tmp/bin:$PATH" VRG_APP_ID=12345 VRG_PRIVATE_KEY_PATH="$tmp/app.pem" \
  bash "$tmp/repo/scripts/vrg-vm-init.sh" test-identity test-instance \
  < /dev/null > "$tmp/init.out" 2>&1 || init_rc=$?
[ "$init_rc" = 0 ] || { cat "$tmp/init.out" >&2; fail "vrg-vm-init exited $init_rc with no vergil.toml"; }

if grep -nE 'uv |vergil-tooling' "$LIMACTL_LOG"; then
  fail "vrg-vm-init ran a vergil-tooling install in the VM"
fi

# The rest of the script still runs: key, app.env, git HTTPS rewrite, verification.
grep -qF 'app.pem' "$LIMACTL_LOG" || { cat "$LIMACTL_LOG" >&2; fail "did not inject app.pem"; }
grep -qF 'app.env' "$LIMACTL_LOG" || { cat "$LIMACTL_LOG" >&2; fail "did not inject app.env"; }
grep -qF 'url.https://github.com/.insteadOf git@github.com:' "$LIMACTL_LOG" \
  || { cat "$LIMACTL_LOG" >&2; fail "did not configure git for HTTPS"; }
grep -qF 'bash -s' "$LIMACTL_LOG" || { cat "$LIMACTL_LOG" >&2; fail "did not run the credential verification"; }
echo "PASS: vrg-vm-init injects credentials and installs no vergil-tooling"
