#!/usr/bin/env bash
# tests/check-update-deps-hook.sh — Checks for the dependency-update hook
# (scripts/dev/update-deps.sh, epic vergil-project/.github#381). Hermetic: the pure
# helpers are unit-checked directly, and the hook itself runs against a scratch copy of
# the repo with `curl` and `tofu` replaced by stubs on PATH — no network, no real tofu.
# HOST-side. check-* prefix keeps it out of the run-tests.sh in-guest glob.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
# shellcheck source=../scripts/dev/update-deps-lib.sh
. "${ROOT}/scripts/dev/update-deps-lib.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

# --- 1. Pure helpers -----------------------------------------------------------------

[ "$(semver_major 3.0.0)" = "3" ] || fail "semver_major"
[ "$(semver_newest_same_major 2.3.3 2.3.3 2.4.0 2.10.1 2.5.1 3.0.0 2.5.1-rc1)" = "2.10.1" ] \
  || fail "semver_newest_same_major: newest within major (numeric, not lexical, order)"
[ "$(semver_newest_same_major 2.5.1 2.3.3 2.5.1)" = "2.5.1" ] \
  || fail "semver_newest_same_major: already newest"
[ "$(semver_newest_same_major 2.5.1 3.0.0)" = "2.5.1" ] \
  || fail "semver_newest_same_major: only a newer major -> stay on current"
[ "$(semver_newest 2.3.3 10.0.0 9.9.9 3.0.0-rc1)" = "10.0.0" ] || fail "semver_newest"
if semver_newest 3.0.0-rc1 >/dev/null 2>&1; then
  fail "semver_newest must fail loud when there is no stable candidate"
fi

tmp="$(mktemp -d)"; trap 'rm -rf "$tmp"' EXIT
# shellcheck disable=SC2016  # literal ${NERDCTL_VERSION} is the fixture content
printf '      NERDCTL_VERSION=2.3.3\n      x="${NERDCTL_VERSION}"\n' > "$tmp/skel"
set_nerdctl_version "$tmp/skel" 2.5.1
grep -q '^      NERDCTL_VERSION=2.5.1$' "$tmp/skel" || fail "set_nerdctl_version: rewrite"
grep -qF 'x="${NERDCTL_VERSION}"' "$tmp/skel" || fail "set_nerdctl_version: touched other lines"
[ ! -e "$tmp/skel.bak" ] || fail "set_nerdctl_version: left a .bak behind"
printf 'no assignment here\n' > "$tmp/none"
if set_nerdctl_version "$tmp/none" 2.5.1 2>/dev/null; then
  fail "set_nerdctl_version must fail loud when there is no NERDCTL_VERSION= line"
fi

line="$(report_line vergil-vm nerdctl 2.5.1 3.0.0 'newer major')"
[ "$line" = '{"source": "vergil-vm", "name": "nerdctl", "current": "2.5.1", "latest": "3.0.0", "note": "newer major"}' ] \
  || fail "report_line: $line"
line="$(report_line vergil-vm lima 2.0.0 3.1.0)"
[ "$line" = '{"source": "vergil-vm", "name": "lima", "current": "2.0.0", "latest": "3.1.0"}' ] \
  || fail "report_line without note: $line"
line="$(report_line vergil-vm 'a"b' 1 2 'c\d')"
[ "$line" = '{"source": "vergil-vm", "name": "a\"b", "current": "1", "latest": "2", "note": "c\\d"}' ] \
  || fail "report_line must JSON-escape values: $line"
echo "PASS: update-deps-lib helpers"

# --- 2. The hook, against stubs ----------------------------------------------------

# Fixtures served by the curl stub, keyed by URL.
fx="$tmp/fixtures"; mkdir -p "$fx"
release() { # release <tag> [prerelease] -> one GitHub release object
  printf '{"tag_name": "%s", "draft": false, "prerelease": %s}' "$1" "${2:-false}"
}
write_releases() { # write_releases <file> <release-json>...
  local f="$1"; shift
  local IFS=,
  printf '[%s]\n' "$*" > "$f"
}

stubs="$tmp/bin"; mkdir -p "$stubs"
# curl stub: serve a fixture for each known URL; fail (like `curl -f`) otherwise or when
# the URL matches the glob in CURL_FAIL. Logs every URL.
cat_stub_curl() {
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'url="${!#}"' \
    'echo "$url" >> "${STUB_LOG}/curl.log"' \
    'if [ -n "${CURL_FAIL:-}" ] && [[ "$url" == ${CURL_FAIL} ]]; then echo "curl: (22) stub failure" >&2; exit 22; fi' \
    'case "$url" in' \
    '  https://api.github.com/repos/containerd/nerdctl/releases*) f=nerdctl.json ;;' \
    '  https://api.github.com/repos/lima-vm/lima/releases*) f=lima.json ;;' \
    '  https://nodejs.org/dist/index.json) f=node.json ;;' \
    '  *) echo "curl stub: unexpected URL $url" >&2; exit 22 ;;' \
    'esac' \
    'cat "${STUB_FIXTURES}/$f"'
}
cat_stub_curl > "$stubs/curl"
# tofu stub: record the argv, the TF_DATA_DIR, and simulate init writing the lockfile and
# its data dir. TOFU_FAIL makes it fail.
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'echo "TF_DATA_DIR=${TF_DATA_DIR:-} $*" >> "${STUB_LOG}/tofu.log"' \
  '[ -z "${TOFU_FAIL:-}" ] || { echo "tofu stub failure" >&2; exit 1; }' \
  'chdir=""' \
  'for a in "$@"; do case "$a" in -chdir=*) chdir="${a#-chdir=}" ;; esac; done' \
  '[ -n "$chdir" ] || { echo "tofu stub: no -chdir" >&2; exit 2; }' \
  'echo "# relocked by stub" >> "$chdir/.terraform.lock.hcl"' \
  'mkdir -p "${TF_DATA_DIR:-$chdir/.terraform}/providers"' \
  > "$stubs/tofu"
chmod +x "$stubs/curl" "$stubs/tofu"

# The scenarios run against a fixture baseline, not the live repo's pins: the hook's
# whole job is to move NERDCTL_VERSION, so asserting on the live value would break the
# suite every time the hook succeeds. The baseline is a scratch copy of what the hook
# reads and writes, with every vm skeleton normalized to FIXTURE_NERDCTL by the hook's
# own helper (set_nerdctl_version) and cloud-init.yaml regenerated by the hook's own
# generator (build-cloud-init.sh), so the copy is self-consistent whatever the live
# value is. The values the hook only reports — the Lima floor (minimumLimaVersion in
# templates/agent.yaml.skel) and the NodeSource major (setup_<N>.x in
# templates/provision/10-base.sh) — are pinned the same way, so a deliberate manual move
# of either (say, to Node 24) cannot break the expected report. 10-base.sh is inlined
# into agent.yaml and both cloud-init.yaml files, so those are regenerated after the pins.
FIXTURE_NERDCTL=2.3.3
FIXTURE_LIMA_FLOOR=2.0.0
FIXTURE_NODE_MAJOR=22
# pin_one <file> <match-ERE> <sed-ERE-substitution> — apply the substitution to <file>,
# failing loud unless exactly one line matches <match-ERE> before the rewrite.
pin_one() {
  local f="$1" match="$2" subst="$3" n
  n="$(grep -cE "$match" "$f" || true)"
  [ "$n" = 1 ] || fail "baseline: expected exactly one line matching '$match' in ${f#"$baseline/"}, got $n"
  sed -E "$subst" "$f" > "$f.pin" && mv "$f.pin" "$f"
}
baseline="$tmp/baseline"; mkdir -p "$baseline"
cp -R "${ROOT}/scripts" "${ROOT}/templates" "${ROOT}/opentofu" "$baseline/"
rm -rf "$baseline"/opentofu/modules/*/*/.terraform
baseline_skels=("$baseline"/opentofu/modules/*/vm/cloud-init.yaml.skel)
[ "${#baseline_skels[@]}" = 2 ] \
  || fail "baseline: expected the azure and gcp vm skeletons, got: ${baseline_skels[*]}"
for s in "${baseline_skels[@]}"; do set_nerdctl_version "$s" "$FIXTURE_NERDCTL"; done
pin_one "$baseline/templates/agent.yaml.skel" \
  '^minimumLimaVersion: "[0-9]+\.[0-9]+\.[0-9]+"$' \
  "s/^minimumLimaVersion: \"[0-9]+\.[0-9]+\.[0-9]+\"\$/minimumLimaVersion: \"${FIXTURE_LIMA_FLOOR}\"/"
pin_one "$baseline/templates/provision/10-base.sh" \
  'https://deb\.nodesource\.com/setup_[0-9]+\.x' \
  "s#(https://deb\.nodesource\.com/setup_)[0-9]+(\.x)#\1${FIXTURE_NODE_MAJOR}\2#"
bash "$baseline/scripts/build-template.sh" >/dev/null || fail "baseline: build-template.sh failed"
bash "$baseline/scripts/build-template.sh" --check >/dev/null || fail "baseline: agent.yaml stale"
bash "$baseline/scripts/build-cloud-init.sh" >/dev/null || fail "baseline: build-cloud-init.sh failed"
bash "$baseline/scripts/build-cloud-init.sh" --check >/dev/null || fail "baseline: cloud-init.yaml stale"
for p in gcp azure; do
  for f in cloud-init.yaml.skel cloud-init.yaml; do
    [ "$(grep -cxF "      NERDCTL_VERSION=${FIXTURE_NERDCTL}" "$baseline/opentofu/modules/$p/vm/$f")" = 1 ] \
      || fail "baseline: $p/vm/$f not normalized to NERDCTL_VERSION=${FIXTURE_NERDCTL}"
  done
done
for f in templates/agent.yaml.skel templates/agent.yaml; do
  [ "$(grep -cxF "minimumLimaVersion: \"${FIXTURE_LIMA_FLOOR}\"" "$baseline/$f")" = 1 ] \
    || fail "baseline: $f not normalized to minimumLimaVersion ${FIXTURE_LIMA_FLOOR}"
done
for f in templates/provision/10-base.sh templates/agent.yaml \
  opentofu/modules/gcp/vm/cloud-init.yaml opentofu/modules/azure/vm/cloud-init.yaml; do
  [ "$(grep -oE 'https://deb\.nodesource\.com/setup_[0-9]+\.x' "$baseline/$f" | sort -u)" \
    = "https://deb.nodesource.com/setup_${FIXTURE_NODE_MAJOR}.x" ] \
    || fail "baseline: $f not normalized to NodeSource setup_${FIXTURE_NODE_MAJOR}.x"
done

new_repo() { # new_repo <dir> — a fresh copy of the fixture baseline
  mkdir -p "$1"
  cp -R "$baseline/scripts" "$baseline/templates" "$baseline/opentofu" "$1/"
}

run_hook() { # run_hook <repo> — run the hook with stubs; leaves status in $hook_rc
  local repo="$1"
  export STUB_LOG="$repo/.stublog" STUB_FIXTURES="$fx"
  mkdir -p "$STUB_LOG"
  : > "$repo/report.jsonl"
  hook_rc=0
  (cd "$repo" && PATH="$stubs:$PATH" VRG_DEPS_REPORT="$repo/report.jsonl" \
    bash scripts/dev/update-deps.sh) > "$repo/hook.out" 2>&1 || hook_rc=$?
}

# 2a. Newer versions everywhere: nerdctl bumps within its major (2.5.1, not 3.0.0 and not
# the 2.6.0 pre-release); Lima, Node and the nerdctl major are reported, not bumped.
write_releases "$fx/nerdctl.json" "$(release v3.0.0)" "$(release v2.6.0-rc.1 true)" \
  "$(release v2.6.0 true)" "$(release v2.5.1)" "$(release v2.4.0)" "$(release v2.3.3)"
write_releases "$fx/lima.json" "$(release v3.1.0)" "$(release v2.9.0)"
printf '%s\n' '[{"version": "v25.1.0", "lts": false}, {"version": "v24.11.0", "lts": "Krypton"}, {"version": "v22.20.0", "lts": "Jod"}]' \
  > "$fx/node.json"
repo="$tmp/r-bump"; new_repo "$repo"; run_hook "$repo"
[ "$hook_rc" = 0 ] || { cat "$repo/hook.out" >&2; fail "2a: hook exited $hook_rc"; }
for p in gcp azure; do
  grep -q '^      NERDCTL_VERSION=2.5.1$' "$repo/opentofu/modules/$p/vm/cloud-init.yaml.skel" \
    || fail "2a: $p skeleton not bumped to 2.5.1"
  grep -q '^      NERDCTL_VERSION=2.5.1$' "$repo/opentofu/modules/$p/vm/cloud-init.yaml" \
    || fail "2a: $p cloud-init.yaml not regenerated"
done
bash "$repo/scripts/build-cloud-init.sh" --check >/dev/null || fail "2a: cloud-init.yaml stale after hook"
expected_report="$tmp/expected-2a.jsonl"
printf '%s\n' \
  '{"source": "vergil-vm", "name": "nerdctl", "current": "2.5.1", "latest": "3.0.0", "note": "newer major; bump NERDCTL_VERSION in opentofu/modules/*/vm/cloud-init.yaml.skel deliberately"}' \
  '{"source": "vergil-vm", "name": "lima", "current": "2.0.0", "latest": "3.1.0", "note": "newer major than minimumLimaVersion in templates/agent.yaml.skel"}' \
  '{"source": "vergil-vm", "name": "nodesource", "current": "22", "latest": "24", "note": "newest Node LTS major; setup_22.x in templates/provision/10-base.sh"}' \
  > "$expected_report"
diff -u "$expected_report" "$repo/report.jsonl" || fail "2a: report lines"
python3 -c 'import json,sys; [json.loads(l) for l in open(sys.argv[1]) if l.strip()]' "$repo/report.jsonl" \
  || fail "2a: report is not valid JSON lines"
# tofu: one `init -upgrade` per module (4), each with a private TF_DATA_DIR, and nothing
# left behind in the modules.
[ "$(grep -c ' init -backend=false -upgrade -input=false$' "$repo/.stublog/tofu.log")" = 4 ] \
  || { cat "$repo/.stublog/tofu.log" >&2; fail "2a: expected 4 tofu init -upgrade calls"; }
if grep -q '^TF_DATA_DIR= ' "$repo/.stublog/tofu.log"; then fail "2a: tofu ran without TF_DATA_DIR"; fi
for m in gcp/vm gcp/volume azure/vm azure/volume; do
  grep -q "\-chdir=.*/opentofu/modules/$m " "$repo/.stublog/tofu.log" || fail "2a: tofu not run for $m"
  grep -q '# relocked by stub' "$repo/opentofu/modules/$m/.terraform.lock.hcl" || fail "2a: $m lockfile not relocked"
  [ ! -e "$repo/opentofu/modules/$m/.terraform" ] || fail "2a: $m/.terraform left behind"
done
echo "PASS: hook bumps nerdctl within its major, relocks providers, reports majors"

# 2b. Nothing newer: no skeleton change, empty report.
write_releases "$fx/nerdctl.json" "$(release v2.3.3)" "$(release v2.3.2)"
write_releases "$fx/lima.json" "$(release v2.9.0)"
printf '%s\n' '[{"version": "v22.20.0", "lts": "Jod"}]' > "$fx/node.json"
repo="$tmp/r-noop"; new_repo "$repo"; run_hook "$repo"
[ "$hook_rc" = 0 ] || { cat "$repo/hook.out" >&2; fail "2b: hook exited $hook_rc"; }
for p in gcp azure; do
  cmp -s "$repo/opentofu/modules/$p/vm/cloud-init.yaml.skel" "$baseline/opentofu/modules/$p/vm/cloud-init.yaml.skel" \
    || fail "2b: $p skeleton changed with nothing newer"
  cmp -s "$repo/opentofu/modules/$p/vm/cloud-init.yaml" "$baseline/opentofu/modules/$p/vm/cloud-init.yaml" \
    || fail "2b: $p cloud-init.yaml changed with nothing newer"
done
[ ! -s "$repo/report.jsonl" ] || fail "2b: report should be empty"
echo "PASS: hook is a no-op (besides relocking) when nothing is newer"

# 2c. Every failure mode fails loud — never a silent "no change".
expect_fail() { # expect_fail <label> <repo>
  [ "$hook_rc" != 0 ] || { cat "$2/hook.out" >&2; fail "$1: hook should have failed"; }
}
for pat in '*containerd/nerdctl*' '*lima-vm/lima*' '*nodejs.org*'; do
  repo="$tmp/r-curl"; rm -rf "$repo"; new_repo "$repo"
  CURL_FAIL="$pat" run_hook "$repo"; expect_fail "curl failure for $pat" "$repo"
done
# A newer Node LTS exists, so a lookup failure that degraded to "nothing newer" would
# exit 0 with an empty report; it must fail instead.
printf '%s\n' '[{"version": "v24.11.0", "lts": "Krypton"}]' > "$fx/node.json"
repo="$tmp/r-node-curl"; new_repo "$repo"
CURL_FAIL='*nodejs.org*' run_hook "$repo"; expect_fail "node lookup failure" "$repo"
printf '%s\n' '[{"version": "vX.1.0", "lts": "Weird"}]' > "$fx/node.json"
repo="$tmp/r-node-bad"; new_repo "$repo"; run_hook "$repo"; expect_fail "non-numeric Node major" "$repo"
printf '%s\n' '[{"version": "v22.20.0", "lts": "Jod"}]' > "$fx/node.json"
repo="$tmp/r-tofu"; new_repo "$repo"; TOFU_FAIL=1 run_hook "$repo"; expect_fail "tofu failure" "$repo"

write_releases "$fx/nerdctl.json" "$(release v3.0.0-rc.1 true)"
repo="$tmp/r-norel"; new_repo "$repo"; run_hook "$repo"; expect_fail "no stable nerdctl release" "$repo"
write_releases "$fx/nerdctl.json" "$(release v2.3.3)"

printf 'not json\n' > "$fx/lima.json"
repo="$tmp/r-badjson"; new_repo "$repo"; run_hook "$repo"; expect_fail "unparseable lima releases" "$repo"
write_releases "$fx/lima.json" "$(release v2.9.0)"

printf '%s\n' '[{"version": "v25.1.0", "lts": false}]' > "$fx/node.json"
repo="$tmp/r-nolts"; new_repo "$repo"; run_hook "$repo"; expect_fail "no Node LTS" "$repo"
printf '%s\n' '[{"version": "v22.20.0", "lts": "Jod"}]' > "$fx/node.json"

repo="$tmp/r-skew"; new_repo "$repo"
set_nerdctl_version "$repo/opentofu/modules/azure/vm/cloud-init.yaml.skel" 2.3.2
run_hook "$repo"; expect_fail "skeletons disagree on NERDCTL_VERSION" "$repo"

repo="$tmp/r-noreport"; new_repo "$repo"
hook_rc=0
(cd "$repo" && env -u VRG_DEPS_REPORT PATH="$stubs:$PATH" STUB_LOG="$tmp" STUB_FIXTURES="$fx" \
  bash scripts/dev/update-deps.sh) > "$repo/hook.out" 2>&1 || hook_rc=$?
expect_fail "VRG_DEPS_REPORT unset" "$repo"
echo "PASS: hook fails loud on lookup, parse, tofu and consistency errors"

# --- 3. Wiring ------------------------------------------------------------------------

grep -qE '^\[dependency-update\]$' "${ROOT}/vergil.toml" || fail "vergil.toml: no [dependency-update] table"
grep -qE '^hook = "scripts/dev/update-deps.sh"$' "${ROOT}/vergil.toml" \
  || fail "vergil.toml: [dependency-update].hook is not scripts/dev/update-deps.sh"
[ -x "${ROOT}/scripts/dev/update-deps.sh" ] || fail "scripts/dev/update-deps.sh is not executable"
echo "PASS: [dependency-update].hook wired"
echo "check-update-deps-hook: OK"
