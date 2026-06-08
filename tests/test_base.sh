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

echo "test_base: all checks passed"
