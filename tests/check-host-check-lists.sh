#!/usr/bin/env bash
# tests/check-host-check-lists.sh — Assert tests/run-host-tests.sh (run by
# scripts/build.sh) and scripts/bin/validate-custom (run by vrg-validate) run the same
# host-side checks (#407), so a check added to one list cannot silently skip the other.
# Each file holds its list as a `host_checks=(` array between `# --- BEGIN host-checks ---`
# and `# --- END host-checks ---`, one name per line. The one intended difference:
# run-host-tests.sh also runs check-opentofu-validate, which validate-custom covers with
# its own tofu step instead. A failure names each check missing from either side.
# HOST-side. check-* prefix keeps it out of the run-tests.sh in-guest test_*.sh glob.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
fail() { echo "FAIL: $*" >&2; exit 1; }

TOFU_ONLY=check-opentofu-validate

# host_check_list <file> — print the block's check names, one per line. Exits nonzero,
# naming the problem on stderr, on a missing or unclosed block or any line in it that
# is not exactly one check name, so a malformed list is never read as a shorter one.
host_check_list() {
    awk -v file="$1" '
        function bad(msg) { print "host-checks list in " file ": " msg > "/dev/stderr"; err = 1 }
        $0 == "# --- BEGIN host-checks ---" { if (found) bad("more than one BEGIN marker"); on = 1; found = 1; n = 0; next }
        $0 == "# --- END host-checks ---" { if (!on) bad("END marker without BEGIN"); on = 0; closed = 1; next }
        on {
            n++
            if (n == 1) { if ($0 != "host_checks=(") bad("first line is not host_checks=(: " $0); next }
            if (shut) { bad("line after the closing ): " $0); next }
            if ($0 == ")") { shut = 1; next }
            if ($0 !~ /^  check-[a-z0-9-]+$/) { bad("not one check name: " $0); next }
            sub(/^  /, ""); print
        }
        END {
            if (!found) bad("no BEGIN marker")
            else if (on || !closed) bad("no END marker")
            else if (!shut) bad("no closing )")
            exit err
        }' "$1"
}

# compare_lists <run-host-tests file> <validate-custom file> — return 1, naming every
# difference on stderr, unless the two lists match (bar the TOFU_ONLY exception).
compare_lists() {
    local d side rc=0
    d="$(mktemp -d)"
    if ! host_check_list "$1" > "$d/rht" || ! host_check_list "$2" > "$d/vc"; then
        rm -rf "$d"; return 1
    fi
    for side in rht vc; do
        if [ -n "$(sort "$d/$side" | uniq -d)" ]; then
            echo "duplicate checks in ${side}: $(sort "$d/$side" | uniq -d | tr '\n' ' ')" >&2
            rc=1
        fi
    done
    if ! grep -qx "$TOFU_ONLY" "$d/rht"; then
        echo "missing from tests/run-host-tests.sh: ${TOFU_ONLY}" >&2; rc=1
    fi
    if grep -qx "$TOFU_ONLY" "$d/vc"; then
        echo "${TOFU_ONLY} is in scripts/bin/validate-custom's list; its tofu step covers it" >&2; rc=1
    fi
    awk -v x="$TOFU_ONLY" '$0 != x' "$d/rht" | sort -u > "$d/rht.s"
    sort -u "$d/vc" > "$d/vc.s"
    local only_rht only_vc
    only_rht="$(comm -23 "$d/rht.s" "$d/vc.s" | tr '\n' ' ')"
    only_vc="$(comm -13 "$d/rht.s" "$d/vc.s" | tr '\n' ' ')"
    if [ -n "$only_rht" ]; then
        echo "missing from scripts/bin/validate-custom: ${only_rht% }" >&2; rc=1
    fi
    if [ -n "$only_vc" ]; then
        echo "missing from tests/run-host-tests.sh: ${only_vc% }" >&2; rc=1
    fi
    rm -rf "$d"
    return "$rc"
}

RHT="${ROOT}/tests/run-host-tests.sh"
VC="${ROOT}/scripts/bin/validate-custom"
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# 1. The real lists match.
compare_lists "$RHT" "$VC" 2> "$tmp/err" \
    || fail "the host-check lists differ: $(cat "$tmp/err")"
echo "PASS: run-host-tests.sh and validate-custom run the same host checks"

# 2. A check dropped from either side fails, naming the check and the side.
grep -vx '  check-test-base' "$VC" > "$tmp/vc-drop"
if compare_lists "$RHT" "$tmp/vc-drop" 2> "$tmp/err"; then
    fail "a check missing from validate-custom passes"
fi
grep -qx 'missing from scripts/bin/validate-custom: check-test-base' "$tmp/err" \
    || fail "a check missing from validate-custom is not named: $(cat "$tmp/err")"
grep -vx '  check-azure-volume-id-parse' "$RHT" > "$tmp/rht-drop"
if compare_lists "$tmp/rht-drop" "$VC" 2> "$tmp/err"; then
    fail "a check missing from run-host-tests.sh passes"
fi
grep -qx 'missing from tests/run-host-tests.sh: check-azure-volume-id-parse' "$tmp/err" \
    || fail "a check missing from run-host-tests.sh is not named: $(cat "$tmp/err")"
echo "PASS: a check missing from either list fails, naming it and the list"

# 3. A malformed list fails rather than being read as a shorter one.
sed 's/^  check-test-base$/  check-test-base check-extra/' "$VC" > "$tmp/vc-bad"
if compare_lists "$RHT" "$tmp/vc-bad" 2> "$tmp/err"; then
    fail "a line holding two check names passes"
fi
grep -q 'not one check name' "$tmp/err" \
    || fail "a malformed list line is not reported: $(cat "$tmp/err")"
grep -vx '# --- END host-checks ---' "$VC" > "$tmp/vc-noend"
if compare_lists "$RHT" "$tmp/vc-noend" 2> "$tmp/err"; then
    fail "a list with no END marker passes"
fi
echo "PASS: a malformed list fails"

echo "check-host-check-lists: all checks passed"
