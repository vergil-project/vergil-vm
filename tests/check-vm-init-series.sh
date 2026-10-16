#!/usr/bin/env bash
# tests/check-vm-init-series.sh — Assert scripts/vrg-vm-init.sh installs vergil-tooling at
# the series declared in vergil.toml ([dependencies].vergil), not a hard-coded pin, and
# fails loud (before touching the VM) when the series cannot be read. Spec §8.4 of epic
# vergil-project/.github#381. Hermetic: `limactl` is a stub on PATH that records its argv.
# HOST-side. check-* prefix keeps it out of the run-tests.sh in-guest glob.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

if grep -nE 'vergil-tooling@v[0-9]' "${ROOT}/scripts/vrg-vm-init.sh"; then
  fail "scripts/vrg-vm-init.sh hard-codes a vergil-tooling series"
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'printf "%s\n" "$*" >> "${LIMACTL_LOG}"' \
  'cat > /dev/null' \
  > "$tmp/bin/limactl"
chmod +x "$tmp/bin/limactl"
: > "$tmp/app.pem"

run_init() { # run_init <repo> — run the repo's vrg-vm-init.sh with the stub; sets init_rc
  export LIMACTL_LOG="$1/limactl.log"
  : > "$LIMACTL_LOG"
  init_rc=0
  PATH="$tmp/bin:$PATH" VRG_APP_ID=12345 VRG_PRIVATE_KEY_PATH="$tmp/app.pem" \
    bash "$1/scripts/vrg-vm-init.sh" test-identity test-instance \
    < /dev/null > "$1/init.out" 2>&1 || init_rc=$?
}

new_repo() { # new_repo <dir> <vergil.toml content>
  mkdir -p "$1/scripts"
  cp "${ROOT}/scripts/vrg-vm-init.sh" "${ROOT}/scripts/vm-verify-credentials.sh" "$1/scripts/"
  printf '%s\n' "$2" > "$1/vergil.toml"
}

# The real vergil.toml's series is what gets installed.
series="$(sed -n -E 's/^vergil = "(v[0-9]+\.[0-9]+)"$/\1/p' "${ROOT}/vergil.toml")"
[ -n "$series" ] || fail "fixture assumption: vergil.toml declares [dependencies].vergil"
repo="$tmp/r-real"
new_repo "$repo" "$(cat "${ROOT}/vergil.toml")"
run_init "$repo"
[ "$init_rc" = 0 ] || { cat "$repo/init.out" >&2; fail "vrg-vm-init exited $init_rc"; }
grep -qF "vergil-tooling @ git+https://github.com/vergil-project/vergil-tooling@${series}\"" "$repo/limactl.log" \
  || { cat "$repo/limactl.log" >&2; fail "did not install vergil-tooling@${series}"; }

# A different declared series is followed, and only [dependencies].vergil counts.
repo="$tmp/r-other"
new_repo "$repo" "$(printf '[project]\nname = "x"\n\n[other]\nvergil = "v1.0"\n\n[dependencies]\nvergil = "v9.7"\n')"
run_init "$repo"
[ "$init_rc" = 0 ] || { cat "$repo/init.out" >&2; fail "v9.7: vrg-vm-init exited $init_rc"; }
grep -qF 'vergil-tooling@v9.7"' "$repo/limactl.log" || { cat "$repo/limactl.log" >&2; fail "did not follow vergil.toml series v9.7"; }

# No series declared -> fail loud before any limactl call.
repo="$tmp/r-missing"
new_repo "$repo" "$(printf '[project]\nname = "x"\n\n[other]\nvergil = "v1.0"\n')"
run_init "$repo"
[ "$init_rc" != 0 ] || fail "missing [dependencies].vergil: vrg-vm-init should fail"
[ ! -s "$repo/limactl.log" ] || fail "missing [dependencies].vergil: limactl was called before failing"
grep -q 'dependencies' "$repo/init.out" || fail "missing series: error does not name [dependencies].vergil"
echo "PASS: vrg-vm-init installs vergil-tooling at the vergil.toml series"
