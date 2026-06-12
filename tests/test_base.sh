#!/bin/bash
# tests/test_base.sh — Verify base OS configuration.
set -euo pipefail

# Ubuntu 24.04
grep -q 'Ubuntu' /etc/os-release
grep -q 'VERSION_ID="24.04"' /etc/os-release

# Default shell is zsh
getent passwd "$(whoami)" | grep -q '/bin/zsh'

# Passwordless sudo works
sudo -n true

# Claude Code background autoupdater disabled image-wide (issues #85, #110).
# Authoritative mechanism: managed settings, read from disk at every Claude
# Code process start — independent of PAM timing, SSH ControlMaster reuse,
# and shell init. Asserting the var in THIS session's environment (the old
# #85 check) is connection-timing-dependent and proved nothing about real
# agent sessions, so we assert the on-disk mechanisms instead.
[ "$(yq -p json -oy '.env.DISABLE_AUTOUPDATER' /etc/claude-code/managed-settings.json)" = "1" ]

# Defense-in-depth env-file line still present (issue #85).
grep -q '^DISABLE_AUTOUPDATER=1$' /etc/environment

# Identity-mode export lives in ~/.zshenv, not ~/.bashrc (issue #148). zsh is
# the VM shell and never sources ~/.bashrc, so the old bashrc-only export was
# invisible to every zsh session; ~/.zshenv is the hook sourced for every zsh
# invocation. We assert the on-disk mechanism (same rationale as the
# DISABLE_AUTOUPDATER checks above), not the runtime env var, which depends on
# whether this particular test shell sourced an rc file. The export is guarded
# on the mode file so it is present in the image even before credentials are
# injected.
grep -q 'VRG_IDENTITY_MODE' "$HOME/.zshenv"
grep -q '\.config/vergil/identity-mode' "$HOME/.zshenv"

# Interactive prompt is identity-aware (issue #153). The prompt derives the
# agent role from VRG_IDENTITY_MODE and colors only the role token, so a human
# logging in can tell user/audit apart at a glance. Assert the on-disk .zshrc
# mechanism, consistent with the checks above. Use fixed-string grep so the
# brackets/braces are matched literally.
grep -qF 'case "${VRG_IDENTITY_MODE:-}" in' "$HOME/.zshrc"
grep -qF 'PROMPT="[role=' "$HOME/.zshrc"

# Generic interactive zsh defaults (issue #171). Assert the on-disk .zshrc
# mechanism, consistent with the prompt/identity checks above — these options
# only take effect in interactive zsh sessions, so checking this test shell's
# runtime state would be init-path dependent and prove nothing. The two
# papercuts that motivated the collection (Ctrl-D no longer dropping the shell;
# `#` honored on the command line) plus the silenced bell are the load-bearing
# assertions; the rest of the collection is spot-checked.
grep -q 'setopt IGNORE_EOF' "$HOME/.zshrc"
grep -q 'setopt INTERACTIVE_COMMENTS' "$HOME/.zshrc"
grep -q 'unsetopt BEEP' "$HOME/.zshrc"
grep -q 'setopt EXTENDED_HISTORY' "$HOME/.zshrc"
grep -q 'setopt HIST_IGNORE_SPACE' "$HOME/.zshrc"
grep -q 'setopt AUTO_PUSHD' "$HOME/.zshrc"
grep -q 'setopt EXTENDED_GLOB' "$HOME/.zshrc"
# The deferred personal-override hook must NOT be present: a ~/.zshrc.local
# source line implies a managed file the VM has no mechanism to maintain.
! grep -q 'zshrc.local' "$HOME/.zshrc"

echo "test_base: all checks passed"
