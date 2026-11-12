#!/bin/bash
# tests/test_base.sh — Verify base OS configuration.
#
# Runs in the guest (run-tests.sh pipes it to `bash -s`). Every assertion goes through
# check(), so a failure names itself instead of exiting silently under errexit (#407).
# The host-side tests/check-test-base.sh sources this file for its definitions only and
# runs the shell-rc checks against the provisioner's own ~/.zshrc and ~/.zshenv text.
set -euo pipefail

# check <name> <command> [args...] — run the command; on failure print the check's name
# to stderr and exit 1.
check() {
    local name="$1"
    shift
    if ! "$@"; then
        echo "test_base: FAIL: ${name}" >&2
        exit 1
    fi
}

# absent <command> [args...] — succeed when the command fails (negates a grep).
absent() { ! "$@"; }

# rc_setting <pattern> <file> — the file has an uncommented line starting with the
# pattern (ERE). A comment that merely mentions the setting does not satisfy it.
rc_setting() { grep -qE "^[[:space:]]*$1" "$2"; }

# rc_mentions <pattern> <file> — the file's text before any `#` on some line matches
# the pattern (ERE). Used negated: the provisioner's explanatory comments name settings
# it deliberately does NOT provision (#407), and those must not count as present.
rc_mentions() { grep -qE "^[^#]*$1" "$2"; }

# check_shell_rc <zshrc> <zshenv> — the on-disk zsh rc mechanisms the provisioner writes.
check_shell_rc() {
    local zshrc="$1" zshenv="$2"

    # Identity-mode export lives in ~/.zshenv, not ~/.bashrc (issue #148). zsh is the
    # VM shell and never sources ~/.bashrc, so the old bashrc-only export was invisible
    # to every zsh session; ~/.zshenv is the hook sourced for every zsh invocation. We
    # assert the on-disk mechanism (same rationale as the DISABLE_AUTOUPDATER checks),
    # not the runtime env var, which depends on whether this particular test shell
    # sourced an rc file. The export is guarded on the mode file so it is present in the
    # image even before credentials are injected.
    check "zshenv exports VRG_IDENTITY_MODE" grep -q 'VRG_IDENTITY_MODE' "$zshenv"
    check "zshenv reads the identity-mode file" \
        grep -q '\.config/vergil/identity-mode' "$zshenv"

    # Interactive prompt is identity-aware (issue #153). The prompt derives the agent
    # role from VRG_IDENTITY_MODE and colors only the role token, so a human logging in
    # can tell user/audit apart at a glance. Fixed-string grep so the brackets/braces
    # are matched literally.
    # shellcheck disable=SC2016  # literal ${VRG_IDENTITY_MODE:-} is the .zshrc text being matched
    check "zshrc prompt switches on VRG_IDENTITY_MODE" \
        grep -qF 'case "${VRG_IDENTITY_MODE:-}" in' "$zshrc"
    check "zshrc sets the role prompt" grep -qF 'PROMPT="[role=' "$zshrc"

    # Generic interactive zsh defaults (issue #171). These options only take effect in
    # interactive zsh sessions, so checking this test shell's runtime state would be
    # init-path dependent and prove nothing. The two papercuts that motivated the
    # collection (Ctrl-D no longer dropping the shell; `#` honored on the command line)
    # plus the silenced bell are the load-bearing assertions; the rest is spot-checked.
    local opt
    for opt in 'setopt IGNORE_EOF' 'setopt INTERACTIVE_COMMENTS' 'unsetopt BEEP' \
               'setopt EXTENDED_HISTORY' 'setopt HIST_IGNORE_SPACE' 'setopt AUTO_PUSHD' \
               'setopt EXTENDED_GLOB'; do
        check "zshrc has '${opt}'" rc_setting "$opt" "$zshrc"
    done

    # The deferred personal-override hook must NOT be present: a ~/.zshrc.local source
    # line implies a managed file the VM has no mechanism to maintain. The provisioner's
    # own comment explaining that names ~/.zshrc.local, so comments are ignored (#407).
    check "zshrc has no ~/.zshrc.local override hook" \
        absent rc_mentions 'zshrc\.local' "$zshrc"

    # Single-.venv model (issue #282, epic vergil-project/.github#179). The retired
    # dual-venv split provisioned UV_PROJECT_ENVIRONMENT=.venv-host into ~/.zshrc; the
    # container now structurally masks /workspace/.venv, so a single host .venv is safe
    # and .venv-host is obsolete. Assert the export is provisioned NOWHERE in the VM
    # shell env — neither the interactive ~/.zshrc nor the always-sourced ~/.zshenv.
    check "zshrc does not set UV_PROJECT_ENVIRONMENT" \
        absent rc_mentions 'UV_PROJECT_ENVIRONMENT' "$zshrc"
    check "zshenv does not set UV_PROJECT_ENVIRONMENT" \
        absent rc_mentions 'UV_PROJECT_ENVIRONMENT' "$zshenv"
}

default_shell_is_zsh() { getent passwd "$(whoami)" | grep -q '/bin/zsh'; }

# Sourced (by tests/check-test-base.sh): stop here, with the definitions only.
(return 0 2>/dev/null) && return 0

# Ubuntu 24.04
check "os-release is Ubuntu" grep -q 'Ubuntu' /etc/os-release
check "os-release is 24.04" grep -q 'VERSION_ID="24.04"' /etc/os-release

check "default shell is zsh" default_shell_is_zsh
check "passwordless sudo works" sudo -n true

# Claude Code background autoupdater disabled image-wide (issues #85, #110).
# Authoritative mechanism: managed settings, read from disk at every Claude
# Code process start — independent of PAM timing, SSH ControlMaster reuse,
# and shell init. Asserting the var in THIS session's environment (the old
# #85 check) is connection-timing-dependent and proved nothing about real
# agent sessions, so we assert the on-disk mechanisms instead.
check "managed settings disable the autoupdater" \
    [ "$(yq -p json -oy '.env.DISABLE_AUTOUPDATER' /etc/claude-code/managed-settings.json)" = "1" ]

# Defense-in-depth env-file line still present (issue #85).
check "/etc/environment disables the autoupdater" \
    grep -q '^DISABLE_AUTOUPDATER=1$' /etc/environment

check_shell_rc "$HOME/.zshrc" "$HOME/.zshenv"

echo "test_base: all checks passed"
