#!/usr/bin/env bash
# tests/check-vagrant-plugins.sh — Checks for the vagrant plugin helpers in
# templates/provision/40-profile.sh (#346): the racc seed guard, deterministic
# dependency-resolution failures (named, not retried), and transient-failure
# retries. Hermetic: the helpers are extracted between their BEGIN/END markers and
# run against `sudo`, `vagrant` and `ruby` stubs on PATH — no Lima, no network.
# HOST-side. check-* prefix keeps it out of the run-tests.sh in-guest glob.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
PROFILE="${ROOT}/templates/provision/40-profile.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
sed -n '/^# --- BEGIN vagrant-plugin-helpers/,/^# --- END vagrant-plugin-helpers ---$/p' \
  "$PROFILE" > "$tmp/helpers.sh"
grep -q '^vagrant_plugin_install()' "$tmp/helpers.sh" \
  || fail "could not extract the vagrant plugin helpers from 40-profile.sh"

# --- Stubs ---------------------------------------------------------------------------
mkdir "$tmp/bin"
# sudo -u <user> -H <cmd…> → run <cmd…>
cat > "$tmp/bin/sudo" <<'EOF'
#!/usr/bin/env bash
shift 3
exec "$@"
EOF
# vagrant: each call consumes the next outcome from $STUB_OUTCOMES (space-separated:
# ok | resolve | transient), logging its argv to $STUB_LOG.
cat > "$tmp/bin/vagrant" <<'EOF'
#!/usr/bin/env bash
echo "$*" >> "$STUB_LOG"
n="$(wc -l < "$STUB_LOG")"
outcome="$(echo "$STUB_OUTCOMES" | cut -d' ' -f"$n")"
case "$outcome" in
  ok) echo "Installed the plugin '$3'!" ;;
  resolve)
    printf 'Vagrant failed to properly resolve required dependencies.\nThe reported error is:\n\nUnable to resolve dependency: %s\n' \
      "'nokogiri (~> 1.6)' requires 'racc (~> 1.4)'"
    exit 1 ;;
  transient) printf 'Net::OpenTimeout: execution expired\n\n'; exit 1 ;;
  *) echo "stub vagrant: no outcome for call $n" >&2; exit 2 ;;
esac
EOF
# ruby: the version probe prints $STUB_SYS_RACC; the comparison exits 0 iff ARGV[0] >= ARGV[1].
cat > "$tmp/bin/ruby" <<'EOF'
#!/usr/bin/env bash
case "$2" in
  *find_all_by_name*) [ -n "${STUB_SYS_RACC:-}" ] && echo "$STUB_SYS_RACC"; exit 0 ;;
  *) [ "$(printf '%s\n%s\n' "$3" "$4" | sort -V | tail -n 1)" = "$3" ] ;;
esac
EOF
chmod +x "$tmp/bin/"*

# run <outcomes> <function> [args…] — run a helper in a subshell (helpers `exit 1`
# on failure). Leaves the exit status in $rc and the provision error in $tmp/err.
run() {
  local outcomes="$1"; shift
  : > "$tmp/log"; rm -f "$tmp/err"
  set +e
  (
    export PATH="$tmp/bin:$PATH" STUB_LOG="$tmp/log" STUB_OUTCOMES="$outcomes" VERGIL_USER=tester
    # shellcheck source=/dev/null
    . "$tmp/helpers.sh"
    PROVISION_ERROR="$tmp/err"
    sleep() { :; }
    "$@"
  ) > "$tmp/out" 2>&1
  rc=$?
  set -e
}
calls() { wc -l < "$tmp/log" | tr -d ' '; }

# --- 1. vagrant_plugin_install -------------------------------------------------------

run "ok" vagrant_plugin_install vagrant-libvirt
[ "$rc" = 0 ] || fail "install: success must return 0"
[ "$(calls)" = 1 ] || fail "install: success must not retry"

run "transient ok" vagrant_plugin_install vagrant-libvirt
[ "$rc" = 0 ] || fail "install: a transient failure then success must return 0"
[ "$(calls)" = 2 ] || fail "install: a transient failure must be retried"

run "resolve ok" vagrant_plugin_install vagrant-libvirt
[ "$rc" = 1 ] || fail "install: a dependency-resolution error must fail"
[ "$(calls)" = 1 ] || fail "install: a dependency-resolution error must NOT be retried"
grep -qF "Unable to resolve dependency: 'nokogiri (~> 1.6)' requires 'racc (~> 1.4)'" "$tmp/err" \
  || fail "install: provision-error must carry vagrant's resolver message"
grep -q 'unreachable' "$tmp/err" && fail "install: provision-error must not guess at the network"

run "transient transient transient" vagrant_plugin_install vagrant-libvirt
[ "$rc" = 1 ] || fail "install: three transient failures must fail"
[ "$(calls)" = 3 ] || fail "install: transient failures must be retried 3 times"
grep -qF 'last error: Net::OpenTimeout: execution expired' "$tmp/err" \
  || fail "install: provision-error must name the last error after the retries"

run "ok" vagrant_plugin_install racc --plugin-version 1.8.1
grep -qx 'plugin install racc --plugin-version 1.8.1' "$tmp/log" \
  || fail "install: extra install args must be passed through to vagrant"

# --- 2. vagrant_racc_seed_check ------------------------------------------------------

seed="$(sed -n 's/^VAGRANT_RACC_SEED=//p' "$tmp/helpers.sh")"
[ -n "$seed" ] || fail "seed: VAGRANT_RACC_SEED is not set"

STUB_SYS_RACC=1.7.3 run "" vagrant_racc_seed_check
[ "$rc" = 0 ] || fail "seed: an older system racc must pass"

STUB_SYS_RACC="" run "" vagrant_racc_seed_check
[ "$rc" = 0 ] || fail "seed: no system racc must pass"

STUB_SYS_RACC="$seed" run "" vagrant_racc_seed_check
[ "$rc" = 1 ] || fail "seed: a system racc equal to the seed must fail"
grep -q 'bump VAGRANT_RACC_SEED' "$tmp/err" || fail "seed: provision-error must say to bump the seed"

STUB_SYS_RACC=99.0.0 run "" vagrant_racc_seed_check
[ "$rc" = 1 ] || fail "seed: a system racc newer than the seed must fail"

# --- 3. Wiring: the seed runs before the declared plugins ----------------------------

seed_line="$(grep -n 'vagrant_plugin_install racc --plugin-version' "$PROFILE" | cut -d: -f1)"
loop_line="$(grep -n '^  for _p in \$PLUGINS; do' "$PROFILE" | cut -d: -f1)"
[ -n "$seed_line" ] && [ -n "$loop_line" ] || fail "wiring: seed install or plugin loop not found"
[ "$seed_line" -lt "$loop_line" ] || fail "wiring: the racc seed must install before the plugin loop"

echo "PASS: vagrant plugin helpers (racc seed, resolver errors named and not retried, transient retries)"
