#!/bin/bash
# tests/test_credentials.sh — Verify credential file structure.
#
# Runs inside the VM after vrg-vm-init. Tests only the
# credential file layout and git config — not API connectivity,
# which requires live network access.
set -euo pipefail

# App credentials exist with correct permissions
test -f ~/.config/vergil/app.pem
perms=$(stat -c '%a' ~/.config/vergil/app.pem 2>/dev/null || stat -f '%Lp' ~/.config/vergil/app.pem)
test "$perms" = "600"

test -f ~/.config/vergil/app.env
perms=$(stat -c '%a' ~/.config/vergil/app.env 2>/dev/null || stat -f '%Lp' ~/.config/vergil/app.env)
test "$perms" = "600"

# app.env contains APP_ID
grep -q '^APP_ID=' ~/.config/vergil/app.env

# Git uses HTTPS for GitHub
git config --global url.https://github.com/.insteadOf | grep -q 'git@github.com:'
