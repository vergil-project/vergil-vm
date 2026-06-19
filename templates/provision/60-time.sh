#!/bin/bash
set -eux -o pipefail
# Backend-neutral inputs (#199): Lima/cloud each write this file their own way.
. /etc/vergil/provision.env
PKGS="$EXTRA_PACKAGES"
PLUGINS="$VAGRANT_PLUGINS"
NESTED="$NESTED_VIRT"

# Same libvirt-stack signal the group block derives: a VM that hosts nested
# libvirt guests is the natural NTP authority for them.
SERVE=false
case " ${PKGS} " in *" libvirt-daemon-system "*) SERVE=true ;; esac
case " ${PLUGINS} " in *" vagrant-libvirt "*) SERVE=true ;; esac
if [ "${NESTED}" = "true" ]; then SERVE=true; fi

mkdir -p /etc/vergil
printf '%s\n' "${SERVE}" > /etc/vergil/ntp-server.requested

# Base config — clock reliability for every Vergil VM. Heredoc body and
# terminator sit at the YAML block base indent (flush-left after dedent), so
# they land at column 0 in the executed script (cf. the heredocs above).
cat > /etc/chrony/chrony.conf <<'CHRONY'
# Managed by vergil-vm (issue #187) — do not hand-edit; rebuild the VM.

# Upstream discipline when reachable (Ubuntu's default pool; no new trust).
pool ntp.ubuntu.com iburst maxsources 4

# Step the clock for any offset over 1s, at ANY time (the -1 = unlimited,
# not just the first N updates) so a post-boot suspend jump self-corrects.
makestep 1.0 -1

# Hold a good estimate between syncs / across reboots, and discipline the RTC.
driftfile /var/lib/chrony/chrony.drift
rtcsync
CHRONY

# NTP authority for nested guests — appended only for libvirt-stack VMs.
if [ "${SERVE}" = "true" ]; then
  cat >> /etc/chrony/chrony.conf <<'CHRONY_SERVE'

# Serve NTP to nested libvirt guests. The template can't know a VM's
# declared host-only subnets, so allow the RFC1918 ranges those networks
# draw from; the host's gateway address on each bridge is a valid server
# once chrony listens here. Time-only — no other surface is exposed.
allow 10.0.0.0/8
allow 172.16.0.0/12
allow 192.168.0.0/16

# Stay a valid source with no upstream reachable, so the nested fleet stays
# internally consistent offline (agreement beats absolute accuracy).
local stratum 10
CHRONY_SERVE
fi

# chrony owns the clock — mask AND stop timesyncd so the two daemons never
# duel (acceptance #4). `--now` closes the window where a running timesyncd
# lingers after masking. `mask` is not allowed to fail silently: timesyncd
# ships on this image, so a failure is a real anomaly — let set -e abort.
if systemctl cat systemd-timesyncd.service >/dev/null 2>&1; then
  systemctl mask --now systemd-timesyncd.service
fi

# Apply the config. enable --now is idempotent; restart picks up a changed
# conf on later boots. A failure here means the box would ship with the
# clock undisciplined — abort loudly rather than ship it (no silent failure).
systemctl enable chrony
systemctl restart chrony
