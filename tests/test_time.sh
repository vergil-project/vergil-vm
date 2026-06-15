#!/bin/bash
# tests/test_time.sh — Assert the chrony time stack matches the build (issue #187).
#
# Auto-discovered by run-tests.sh; runs in-guest against a built VM. Two
# concerns, both asserted here:
#
#   Clock reliability (EVERY VM). chrony is installed and running, configured
#   with aggressive `makestep` so a post-suspend jump steps back into sync, and
#   systemd-timesyncd is masked so the two daemons never duel (acceptance #4).
#
#   NTP authority (libvirt-stack VMs). The time provisioning step stamps
#   /etc/vergil/ntp-server.requested with its derived decision: "true" when the
#   profile declares the libvirt stack (libvirt-daemon-system in packages,
#   vagrant-libvirt in vagrant_plugins, or nested = true), "false" otherwise.
#   The contract is two-sided: requested ⇒ chrony.conf serves the nested fleet
#   (`allow` the private ranges + a `local stratum` offline fallback), and
#   not-requested ⇒ none of that surface is present (the base box must not
#   silently open an NTP server).
#
# NOT `set -e`: run every assertion, then report. Exit 1 if any failed.
set -uo pipefail
fail=0

CONF=/etc/chrony/chrony.conf
MARKER=/etc/vergil/ntp-server.requested

echo "== Clock reliability (every VM) =="

if systemctl is-active --quiet chrony; then
    echo "  PASS: chrony active"
else
    echo "  FAIL: chrony not active"; fail=1
fi

if command -v chronyc >/dev/null 2>&1; then
    echo "  PASS: chronyc resolves"
else
    echo "  FAIL: chronyc missing"; fail=1
fi

# timesyncd must be masked — chrony owns the clock, no dueling daemons.
state=$(systemctl is-enabled systemd-timesyncd 2>/dev/null || true)
if [ "$state" = "masked" ]; then
    echo "  PASS: systemd-timesyncd masked"
else
    echo "  FAIL: systemd-timesyncd expected masked, got '${state:-absent}'"; fail=1
fi

if [ ! -f "$CONF" ]; then
    echo "  FAIL: $CONF missing (time provisioning step did not run)"; fail=1
else
    # `-1` count = step at any time, not just the first N updates — the whole
    # point for suspend recovery long after boot.
    if grep -Eq '^[[:space:]]*makestep[[:space:]]+1(\.0)?[[:space:]]+-1[[:space:]]*$' "$CONF"; then
        echo "  PASS: makestep configured to step at any time"
    else
        echo "  FAIL: $CONF missing 'makestep 1.0 -1'"; fail=1
    fi
    if grep -Eq '^[[:space:]]*pool[[:space:]]' "$CONF"; then
        echo "  PASS: upstream pool configured"
    else
        echo "  FAIL: $CONF declares no upstream pool"; fail=1
    fi
fi

echo "== NTP authority (libvirt-stack VMs) =="

if [ ! -f "$MARKER" ]; then
    echo "  FAIL: $MARKER missing (time provisioning step did not run)"; fail=1
    requested=missing
else
    requested="$(tr -d '[:space:]' < "$MARKER")"
fi

serves_conf() { # true if chrony.conf carries the nested-guest serving surface
    [ -f "$CONF" ] || return 1
    grep -Eq '^[[:space:]]*allow[[:space:]]' "$CONF" \
        && grep -Eq '^[[:space:]]*local[[:space:]]+stratum[[:space:]]' "$CONF"
}

case "$requested" in
true)
    if serves_conf; then
        echo "  PASS: serving requested and chrony.conf serves (allow + local stratum)"
    else
        echo "  FAIL: serving requested but chrony.conf lacks allow / local stratum"; fail=1
    fi
    ;;
false)
    if serves_conf; then
        echo "  FAIL: serving not requested but chrony.conf opens an NTP server"; fail=1
    else
        echo "  PASS: serving not requested and no NTP server surface present"
    fi
    ;;
*)
    echo "  FAIL: unexpected marker value '$requested'"; fail=1
    ;;
esac

if [ "$fail" -ne 0 ]; then
    echo "test_time: FAIL"
    exit 1
fi
echo "test_time: all checks passed"
