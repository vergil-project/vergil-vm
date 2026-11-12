#!/usr/bin/env bash
# tests/check-test-base.sh — Host-side checks for tests/test_base.sh's shell-rc
# assertions (#407). test_base.sh itself runs in the guest; this sources it for its
# definitions only and runs check_shell_rc against fixture ~/.zshrc / ~/.zshenv files
# built from the provisioner's own heredocs in templates/provision/30-toolchain.sh, so a
# provisioner comment that trips an assertion fails here, before any VM is built.
# HOST-side. check-* prefix keeps it out of the run-tests.sh in-guest test_*.sh glob.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
# vrg-validate lints without -x, so it cannot follow this source; test_base.sh is
# linted on its own.
# shellcheck disable=SC1091
. "${HERE}/test_base.sh"
fail() { echo "FAIL: $*" >&2; exit 1; }

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

# heredoc_body <file> <target> <marker> — the body of `cat > "$HOME/<target>" << '<marker>'`.
heredoc_body() {
    awk -v start="cat > \"\$HOME/$2\" << '$3'" -v end="$3" '
        $0 == start { on = 1; found = 1; next }
        on && $0 == end { on = 0; next }
        on { print }
        END { if (!found) exit 1 }' "$1"
}

prov="${ROOT}/templates/provision/30-toolchain.sh"
heredoc_body "$prov" .zshrc ZSHRC > "$tmp/zshrc" \
    || fail "no ~/.zshrc heredoc found in ${prov}"
heredoc_body "$prov" .zshenv ZSHENV > "$tmp/zshenv" \
    || fail "no ~/.zshenv heredoc found in ${prov}"
[ -s "$tmp/zshrc" ] || fail "the ~/.zshrc heredoc in ${prov} is empty"
[ -s "$tmp/zshenv" ] || fail "the ~/.zshenv heredoc in ${prov} is empty"
# The fixture must carry the comment #407 is about, or the first case proves nothing.
grep -q '^#.*zshrc\.local' "$tmp/zshrc" \
    || fail "the provisioned ~/.zshrc no longer has the ~/.zshrc.local comment; update this check"

# run_rc <zshrc> <zshenv> — run check_shell_rc in a subshell (check() exits on failure),
# leaving its stderr in $tmp/err and returning its exit status.
run_rc() { ( check_shell_rc "$1" "$2" ) 2> "$tmp/err"; }

# 1. The provisioner's own files pass, comments and all.
run_rc "$tmp/zshrc" "$tmp/zshenv" \
    || fail "check_shell_rc rejects the provisioned files: $(cat "$tmp/err")"
echo "PASS: provisioned ~/.zshrc and ~/.zshenv pass check_shell_rc"

# 2. A real ~/.zshrc.local hook fails, and the failure names the check.
for hook in 'source ~/.zshrc.local' '[ -f ~/.zshrc.local ] && . ~/.zshrc.local'; do
    { cat "$tmp/zshrc"; printf '%s\n' "$hook"; } > "$tmp/zshrc-hook"
    if run_rc "$tmp/zshrc-hook" "$tmp/zshenv"; then
        fail "check_shell_rc accepts a ~/.zshrc.local hook: ${hook}"
    fi
    grep -qx 'test_base: FAIL: zshrc has no ~/.zshrc.local override hook' "$tmp/err" \
        || fail "the hook failure does not name its check: $(cat "$tmp/err")"
done
echo "PASS: a ~/.zshrc.local hook fails, naming its check"

# 3. A UV_PROJECT_ENVIRONMENT export fails in either file; a comment naming it does not.
{ cat "$tmp/zshrc"; echo 'export UV_PROJECT_ENVIRONMENT=.venv-host'; } > "$tmp/zshrc-uv"
if run_rc "$tmp/zshrc-uv" "$tmp/zshenv"; then
    fail "check_shell_rc accepts UV_PROJECT_ENVIRONMENT in ~/.zshrc"
fi
grep -qx 'test_base: FAIL: zshrc does not set UV_PROJECT_ENVIRONMENT' "$tmp/err" \
    || fail "the ~/.zshrc UV failure does not name its check: $(cat "$tmp/err")"
{ cat "$tmp/zshenv"; echo 'export UV_PROJECT_ENVIRONMENT=.venv-host'; } > "$tmp/zshenv-uv"
if run_rc "$tmp/zshrc" "$tmp/zshenv-uv"; then
    fail "check_shell_rc accepts UV_PROJECT_ENVIRONMENT in ~/.zshenv"
fi
grep -qx 'test_base: FAIL: zshenv does not set UV_PROJECT_ENVIRONMENT' "$tmp/err" \
    || fail "the ~/.zshenv UV failure does not name its check: $(cat "$tmp/err")"
{ cat "$tmp/zshrc"; echo '# UV_PROJECT_ENVIRONMENT is no longer provisioned'; } > "$tmp/zshrc-uvc"
run_rc "$tmp/zshrc-uvc" "$tmp/zshenv" \
    || fail "a comment naming UV_PROJECT_ENVIRONMENT fails check_shell_rc: $(cat "$tmp/err")"
echo "PASS: UV_PROJECT_ENVIRONMENT is caught as a setting, not as a comment"

# 4. A required option that survives only in a comment does not count.
grep -v '^setopt IGNORE_EOF$' "$tmp/zshrc" > "$tmp/zshrc-noeof"
echo '# setopt IGNORE_EOF' >> "$tmp/zshrc-noeof"
if run_rc "$tmp/zshrc-noeof" "$tmp/zshenv"; then
    fail "check_shell_rc accepts 'setopt IGNORE_EOF' present only in a comment"
fi
grep -qx "test_base: FAIL: zshrc has 'setopt IGNORE_EOF'" "$tmp/err" \
    || fail "the missing-option failure does not name its check: $(cat "$tmp/err")"
echo "PASS: a commented-out required option fails, naming its check"

# 5. check() itself: a passing command is silent, a failing one exits 1 naming itself.
( check "demo passes" true ) 2> "$tmp/err" || fail "check exits on a passing command"
[ ! -s "$tmp/err" ] || fail "check writes to stderr on a passing command: $(cat "$tmp/err")"
set +e
( check "demo fails" false; echo "not reached" ) > "$tmp/out" 2> "$tmp/err"
rc=$?
set -e
[ "$rc" -eq 1 ] || fail "check exits ${rc}, not 1, on a failing command"
[ ! -s "$tmp/out" ] || fail "check does not stop the script on a failing command"
grep -qx 'test_base: FAIL: demo fails' "$tmp/err" \
    || fail "a failing check does not name itself: $(cat "$tmp/err")"
echo "PASS: a failing check exits 1 and names itself"

echo "check-test-base: all checks passed"
