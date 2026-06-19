#!/bin/bash
set -eux -o pipefail
export DEBIAN_FRONTEND=noninteractive

# MASK — unneeded units. The `systemctl cat` gate skips units this image
# doesn't ship (so we don't create dead /dev/null links). For a unit that
# IS present, `mask` is not allowed to fail silently: a gated unit should
# always mask, so a failure is a real anomaly — let set -e abort the build
# loudly rather than ship a VM with an unmasked unit we meant to strip.
mask_if_present() {
  local u
  for u in "$@"; do
    if systemctl cat "$u" >/dev/null 2>&1; then
      systemctl mask "$u"
    fi
  done
}

mask_if_present \
  getty@tty1.service \
  ModemManager.service \
  multipathd.service multipathd.socket \
  udisks2.service \
  apport.service apport-forward.socket \
    apport-autoreport.path apport-autoreport.timer \
  open-iscsi.service iscsid.socket \
  open-vm-tools.service vgauth.service \
  sysstat.service sysstat-collect.timer sysstat-summary.timer \
  systemd-networkd-wait-online.service \
  ubuntu-advantage.service ua-reboot-cmds.service ua-timer.timer \
  fwupd-refresh.timer \
  mdcheck_continue.timer mdcheck_start.timer mdmonitor-oneshot.timer \
  update-notifier-download.timer update-notifier-motd.timer \
  lxd-installer.socket \
  motd-news.service motd-news.timer \
  apt-daily.timer apt-daily-upgrade.timer

# PURGE — curated dead weight. Stop snapd first so purge is clean; the
# stop keeps `|| true` because stopping an absent unit exits non-zero
# (images without snapd). The purge/autoremove do NOT swallow errors:
# apt-get exits 0 when there's nothing to remove, so `|| true` there would
# only ever hide a genuine failure and ship a VM that still has snapd.
# set -e then aborts provisioning visibly on a real purge failure.
systemctl stop snapd.socket snapd.service 2>/dev/null || true
apt-get purge -y snapd unattended-upgrades
apt-get autoremove -y --purge
