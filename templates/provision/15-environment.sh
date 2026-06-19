#!/bin/bash
set -eux -o pipefail
USER_HOME="$(getent passwd "{{.User}}" | cut -d: -f6)"
sed -i "s|^PATH=.*|PATH=\"${USER_HOME}/.local/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin:/usr/games:/usr/local/games\"|" /etc/environment

# Disable Claude Code's background autoupdater image-wide (issues #85,
# #110). The npm global prefix is root-owned but sessions run as the
# non-root Lima user, so the background update can't write there and
# spams the status line every session.
#
# The authoritative mechanism is managed settings: Claude Code reads
# /etc/claude-code/managed-settings.json from disk at process start, so
# it applies on every spawn path. The /etc/environment line below is NOT
# sufficient on its own (issue #110): pam_env snapshots the file once,
# when an SSH session opens, and Lima's ControlMaster multiplexing reuses
# that single PAM environment for every later `limactl shell` channel —
# a master connection opened before this script appends the line never
# sees it. Claude Code is also spawned as a direct child of sshd (no
# shell, SHLVL=0), so the ~/.zshrc export never runs on that path. The
# env line stays as defense in depth for tooling that inspects the
# variable directly.
#
# We use DISABLE_AUTOUPDATER, not DISABLE_UPDATES, so a deliberate
# `claude update` still works — only the failing background attempt is
# suppressed. Version control of Claude Code stays deliberate via rebuild.
mkdir -p /etc/claude-code
cat > /etc/claude-code/managed-settings.json << 'JSON'
{
  "env": {
    "DISABLE_AUTOUPDATER": "1"
  }
}
JSON
chmod 644 /etc/claude-code/managed-settings.json
grep -q '^DISABLE_AUTOUPDATER=' /etc/environment \
  || echo 'DISABLE_AUTOUPDATER=1' >> /etc/environment
