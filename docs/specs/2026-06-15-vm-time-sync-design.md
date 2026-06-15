# Base-VM time sync: chrony + makestep, NTP authority for nested guests

- **Issue:** #187
- **Status:** implemented
- **Date:** 2026-06-15

## Problem

A laptop suspend left a nested-lab observability VM ~65 minutes ahead of its
sibling guest VMs. Stock Ubuntu `systemd-timesyncd` did **not** recover: it
slow-*slews* and will not *step* a large offset, so the skew sat uncorrected
while the daemon reported `NTPSynchronized=yes` the whole time — silent
wrongness. Skewed clocks break cross-node log correlation and event-timeline
reconstruction, the foundation of any multi-node lab's outage analysis.

This is not specific to one repo. **Any** Vergil VM that sleeps with the laptop
wants a clock that steps back into sync on resume, and **any** Vergil VM that
hosts nested libvirt guests is the natural time authority for them. Solving it
once in the base VM avoids N bespoke per-repo hacks against the
"don't hand-customize the VM" model.

## Design

Two jobs, both in `templates/agent.yaml`.

### 1. Clock reliability — every VM

Install **chrony** (in the first-boot base-tools block, network-bound) and
configure it with:

```
pool ntp.ubuntu.com iburst maxsources 4
makestep 1.0 -1
driftfile /var/lib/chrony/chrony.drift
rtcsync
```

`makestep 1.0 -1` steps the clock for any offset over one second, **at any
time** — the `-1` count means "always", not "only the first N updates". That is
the suspend-recovery behaviour: a jump that lands hours after boot still gets
stepped on the next poll, rather than slewed forever like timesyncd.

`systemd-timesyncd` is **masked** so the two daemons never duel (acceptance #4).
It is consequently removed from the service-minimization KEEP list.

#### Why aggressive `makestep` is safe under clustered workloads

A step shifts the *wall* clock. Corosync's token/membership timers and DRBD's
timers use `CLOCK_MONOTONIC`, which a wall-clock step does not touch — only log
timestamps move, which is exactly the thing we want corrected. The consuming
repo (`mq-cluster-tooling` #186) carries the acceptance test that a step under a
running Pacemaker/DRBD cluster does not destabilize it; this repo does not need
its own cluster to justify the setting.

### 2. NTP authority — VMs that host nested libvirt guests

For VMs that declare the libvirt stack, chrony additionally serves the nested
fleet:

```
allow 10.0.0.0/8
allow 172.16.0.0/12
allow 192.168.0.0/16
local stratum 10
```

A nested guest pointed at the host's gateway address on its host-only bridge
(e.g. `10.50.0.1`) syncs to the host. `local stratum 10` keeps the host a valid
source even with no upstream reachable, so the nested fleet stays **internally
consistent** offline — agreement across the fleet matters more than absolute
accuracy.

The config and serving decision are written by a **dedicated time block that
runs every boot** (the install is first-boot-only, but the config is cheap and
must track the current profile — same pattern as the libvirt-groups,
nested-virt, and port-forward blocks). It stamps `/etc/vergil/ntp-server.requested`
with the decision for the in-guest test suite.

## Decisions on the issue's open questions

- **Template vs script boundary — entirely template-side.** The serving config
  is *generic*: the template never sees a VM's declared host-only subnets, so it
  `allow`s the RFC1918 ranges those networks draw from rather than rendering
  per-VM `allow` lines. The host's gateway address on each bridge is a valid
  server once chrony listens. No `vrg-vm` / vergil-tooling change is needed.

- **Serving: opt-in, not default-on.** Gated on the *same* libvirt-stack signal
  the group block already derives (`libvirt-daemon-system` in `EXTRA_PACKAGES`,
  `vagrant-libvirt` in `VAGRANT_PLUGINS`, or `NESTED_VIRT = true`). A base VM
  with no nested guests must not open the NTP server port (service-surface
  minimization, #78).

- **`makestep` threshold + poll cadence.** `makestep 1.0 -1` (1 s threshold,
  unlimited steps). Upstream poll uses the pool defaults plus `iburst` for fast
  initial convergence; a suspend jump is corrected within a poll regardless of
  interval, because the step fires on the next poll.

- **Package availability.** `chrony` is in the Ubuntu main archive (the build
  path already runs `apt-get update`/`install`); no extra repo or trust.

## Scope: Ubuntu only

This repo ships a single Ubuntu 24.04 Lima template (`templates/agent.yaml`);
there is no RHEL/Alma template to attach config to. The issue's RHEL/Alma
mention is left out of scope until a non-Ubuntu base image exists. The service
unit name (`chrony` on Debian/Ubuntu, `chronyd` on RHEL) is the only
distro-specific knob and would be handled when that image lands.

## Firewall

The minimization block reserves (but does not activate) the netfilter/nftables
units for future egress filtering (vergil-tooling #901). Nothing filters NTP
today, so serving needs no firewall change. When egress filtering lands it must
permit UDP/123 inbound on the host-only bridges.

## Verification

- `tests/test_time.sh` (in-guest, auto-discovered) — chrony active, `chronyc`
  resolves, timesyncd masked, `makestep 1.0 -1` present, and the marker-vs-conf
  serving contract in both directions. On the base build the marker is `false`,
  so it asserts **no** serving surface is present.
- `tests/e2e-nested-virt.sh` (host-side) — a `nested = true` build serves NTP
  (`allow` + `local stratum` present, marker `true`), exercising the serve=true
  branch end-to-end.
