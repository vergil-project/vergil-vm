#!/bin/bash
# tests/test_services.sh — Assert the minimized service surface (intent, not snapshot).
#
# Auto-discovered by run-tests.sh; runs in-guest. Three assertion sets:
#   denylist  — each unit masked / each package purged
#   allowlist — load-bearing units up, toolchain resolves
#   reserved  — Lima guest agent must stay unmasked (egress/load-bearing path)
# NOT `set -e`: run every assertion, then report. Exit 1 if any failed.
#
# The masked/purged lists MUST match templates/agent.yaml's minimization block
# exactly — the test and the template share one reconciled list (issue #78).
set -uo pipefail
fail=0

assert_masked() {
    local unit="$1" state
    state=$(systemctl is-enabled "$unit" 2>/dev/null || true)
    if [ "$state" = "masked" ]; then
        echo "  PASS: $unit masked"
    else
        echo "  FAIL: $unit expected masked, got '${state:-absent}'"
        fail=1
    fi
}

assert_purged() {
    local pkg="$1"
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
        echo "  FAIL: package $pkg expected purged, still installed"
        fail=1
    else
        echo "  PASS: package $pkg absent"
    fi
}

assert_active() {            # assert_active <unit> [user]
    local unit="$1" scope="${2:-system}"
    if [ "$scope" = "user" ]; then
        if systemctl --user is-active --quiet "$unit"; then
            echo "  PASS: (user) $unit active"
        else
            echo "  FAIL: (user) $unit not active"; fail=1
        fi
    else
        if systemctl is-active --quiet "$unit"; then
            echo "  PASS: $unit active"
        else
            echo "  FAIL: $unit not active"; fail=1
        fi
    fi
}

assert_command() {
    local c="$1"
    if command -v "$c" >/dev/null 2>&1; then
        echo "  PASS: $c resolves"
    else
        echo "  FAIL: $c missing"; fail=1
    fi
}

assert_not_masked() {       # reserved units must never be masked
    local unit="$1"
    if [ "$(systemctl is-enabled "$unit" 2>/dev/null || true)" = "masked" ]; then
        echo "  FAIL: $unit is masked but is reserved (must stay unmasked)"
        fail=1
    else
        echo "  PASS: $unit not masked"
    fi
}

# containerd runs as a --user unit; reach the user bus from this non-login shell.
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

echo "== Denylist: services must be masked =="
for u in \
    getty@tty1.service \
    ModemManager.service \
    multipathd.service \
    udisks2.service \
    apport.service \
    open-iscsi.service \
    open-vm-tools.service \
    vgauth.service \
    sysstat.service \
    systemd-networkd-wait-online.service \
    ua-reboot-cmds.service \
    ubuntu-advantage.service \
    motd-news.service \
    ; do
    assert_masked "$u"
done

echo "== Denylist: sockets must be masked =="
for u in \
    apport-forward.socket \
    iscsid.socket \
    lxd-installer.socket \
    multipathd.socket \
    ; do
    assert_masked "$u"
done

echo "== Denylist: paths/timers must be masked =="
for u in \
    apport-autoreport.path \
    apport-autoreport.timer \
    apt-daily.timer \
    apt-daily-upgrade.timer \
    fwupd-refresh.timer \
    mdcheck_continue.timer \
    mdcheck_start.timer \
    mdmonitor-oneshot.timer \
    motd-news.timer \
    sysstat-collect.timer \
    sysstat-summary.timer \
    ua-timer.timer \
    update-notifier-download.timer \
    update-notifier-motd.timer \
    ; do
    assert_masked "$u"
done

echo "== Denylist: packages must be purged =="
for p in snapd unattended-upgrades; do
    assert_purged "$p"
done

echo "== Allowlist: load-bearing must be up =="
assert_active ssh
assert_active systemd-resolved
assert_active systemd-networkd
assert_active containerd user
for c in gh uv claude; do
    assert_command "$c"
done

echo "== Reserved: must stay unmasked =="
# Lima's guest agent coordinates limactl access — masking it breaks everything.
assert_not_masked lima-guestagent.service
# ufw is the egress-filtering reservation (#901) — present but inactive, never masked.
assert_not_masked ufw.service

if [ "$fail" -ne 0 ]; then
    echo "test_services: FAIL"
    exit 1
fi
echo "test_services: all checks passed"
