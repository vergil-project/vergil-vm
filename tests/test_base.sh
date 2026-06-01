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

# Claude Code background autoupdater disabled image-wide (issue #85).
# Set in /etc/environment, so PAM exports it even into this non-login
# `limactl shell` session.
grep -q '^DISABLE_AUTOUPDATER=1$' /etc/environment
[ "${DISABLE_AUTOUPDATER:-}" = "1" ]

echo "test_base: all checks passed"
