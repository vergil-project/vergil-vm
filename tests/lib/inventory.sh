#!/bin/bash
# tests/lib/inventory.sh — Shared in-guest inventory/counting core.
#
# Functions only, NO top-level execution. The host-side wrappers
# (scripts/audit-services.sh, scripts/vm-metrics.sh) concatenate this file
# with a single trailing function call and pipe it into the guest via
# `limactl shell <instance> -- bash -s`. One definition of "how we count the
# surface" so the two wrappers cannot disagree.
#
# grep -c exits 1 on zero matches; `|| true` keeps the captured "0" and
# prevents `set -o pipefail` in the caller from aborting.

inv_services_running() { systemctl list-units --type=service --state=running --no-legend --no-pager | grep -c '\.service' || true; }
inv_units_enabled()    { systemctl list-unit-files --state=enabled --no-legend --no-pager | grep -c . || true; }
# No --all: a masked timer still shows as a dead row under --all (no NEXT/
# ACTIVATES), which would count toward the surface despite being inert. Counting
# only live/scheduled timers makes the before/after delta meaningful.
inv_timers()           { systemctl list-timers --no-legend --no-pager | grep -c '\.timer' || true; }
inv_sockets()          { systemctl list-sockets --no-legend --no-pager | grep -c '\.socket' || true; }
inv_proc_count()       { ps -e --no-headers | wc -l; }
inv_mem_used_kb()      { awk '/^MemTotal:/{t=$2} /^MemAvailable:/{a=$2} END{print t-a}' /proc/meminfo; }
inv_rootfs()           { df -P / | awk 'NR==2{print "used_kb="$3" avail_kb="$4}'; }
inv_boot_time()        { systemd-analyze time 2>/dev/null | head -n1; }

# Compact quantitative snapshot (consumed by vm-metrics.sh).
inv_metrics_block() {
    echo "services_running=$(inv_services_running)"
    echo "units_enabled=$(inv_units_enabled)"
    echo "timers=$(inv_timers)"
    echo "sockets=$(inv_sockets)"
    echo "processes=$(inv_proc_count)"
    echo "mem_used_kb=$(inv_mem_used_kb)"
    echo "rootfs: $(inv_rootfs)"
    echo "boot: $(inv_boot_time)"
}

# Full qualitative dump (consumed by audit-services.sh).
inv_dump_lists() {
    echo "### running services";      systemctl list-units --type=service --state=running --no-pager
    echo "### enabled unit files";    systemctl list-unit-files --state=enabled --no-pager
    echo "### timers";                systemctl list-timers --all --no-pager
    echo "### sockets";               systemctl list-sockets --no-pager
    echo "### systemd-analyze blame"; systemd-analyze blame --no-pager 2>/dev/null || true
    echo "### critical-chain";        systemd-analyze critical-chain --no-pager 2>/dev/null || true
}
