#!/bin/bash
# vergil-provision: context=root cadence=once guard=provisioned.base
set -eux -o pipefail
# Backend-neutral inputs (#199): Lima/cloud each write this file their own way.
. /etc/vergil/provision.env
export DEBIAN_FRONTEND=noninteractive

# First-boot-only (#177). Lima re-runs every provisioning script on every
# boot (cloud-init per-boot runparts — Lima rotates the instance-id each
# boot to force it). These steps are network-bound; re-running them on a
# reboot is slow (a full apt re-download, npm, curl installers) and, under
# `set -e`, turns any transient apt/npm/registry timeout into a failed
# boot. This box is rebuilt from scratch, never updated in place, so
# install once and skip thereafter. The marker is stamped LAST (end of this
# block), so a failed install never leaves the box marked provisioned.
if [ -f /etc/vergil/provisioned.base ]; then exit 0; fi

apt-get update
apt-get install -y --no-install-recommends \
  curl wget unzip \
  jq ripgrep fzf \
  zsh vim tmux nano \
  python3 python3-venv \
  chrony

# chrony — reliable, suspend-resilient time + NTP authority for nested
# libvirt guests (issue #187). Installed here (network-bound, first-boot
# only); its config + the timesyncd handoff + optional NTP serving are
# written by the dedicated time block near the end of provisioning, which
# runs every boot so the serving decision tracks the current profile.

# GitHub CLI
curl -fsSL https://cli.github.com/packages/githubcli-archive-keyring.gpg \
  | dd of=/usr/share/keyrings/githubcli-archive-keyring.gpg 2>/dev/null
chmod go+r /usr/share/keyrings/githubcli-archive-keyring.gpg
echo "deb [arch=$(dpkg --print-architecture) signed-by=/usr/share/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main" \
  | tee /etc/apt/sources.list.d/github-cli.list > /dev/null
apt-get update
apt-get install -y gh

# Node.js (required for Claude Code)
curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
apt-get install -y nodejs

# yq (not in Ubuntu repos — install from GitHub releases)
ARCH=$(dpkg --print-architecture)
curl -fsSL "https://github.com/mikefarah/yq/releases/latest/download/yq_linux_${ARCH}" \
  -o /usr/local/bin/yq
chmod +x /usr/local/bin/yq

# Claude Code (npm global install requires root)
npm install -g @anthropic-ai/claude-code

# Set zsh as default shell for the Lima user
chsh -s /bin/zsh "$VERGIL_USER"

# sshd: accept terminal env vars so Claude Code detects keyboard
# protocol support when accessed over SSH
cat > /etc/ssh/sshd_config.d/10-acceptenv-terminal.conf << 'SSHD_CONF'
AcceptEnv COLORTERM TERM_PROGRAM TERM_PROGRAM_VERSION
SSHD_CONF

# Keep the apt lists cache — do NOT `rm -rf /var/lib/apt/lists/*`. This box
# is rebuilt from scratch, so per-boot cache hygiene buys nothing; the wipe
# only forced the next boot's apt-get update to re-fetch ~46 MB of indices
# (#177). apt-get clean (downloaded .debs) stays — it never forces a
# re-download of the lists.
apt-get clean

# Stamp the first-boot completion marker LAST, only after every install
# above succeeded (#177).
mkdir -p /etc/vergil
touch /etc/vergil/provisioned.base
