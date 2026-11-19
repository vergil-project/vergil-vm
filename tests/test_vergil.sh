#!/bin/bash
# tests/test_vergil.sh — Verify the VM's existing vergil-tooling install: no
# vergil package is installed, and vrg-* resolves to uv's tool bin directory
# (~/.local/bin) on the PATH a non-login remote command gets, with no PATH set
# here (epic vergil-project/.github#1350). Installs and uninstalls nothing.
set -euo pipefail

# No vergil apt package is installed (vergil-tooling, vergil-python*,
# vergil-archive-keyring): vergil-tooling comes from uv only. A package dpkg
# knows only as not-installed is gone; any other state (config-files included)
# is a leftover.
# dpkg-query exits 1 when no package matches, and 2 or more on an error.
dpkg_rc=0
known="$(dpkg-query -W -f='${db:Status-Status} ${Package}\n' 'vergil-*')" || dpkg_rc=$?
if [ "$dpkg_rc" -gt 1 ]; then
    echo "FAIL: dpkg-query exited $dpkg_rc" >&2
    exit 1
fi
leftover="$(printf '%s\n' "$known" | awk 'NF && $1 != "not-installed"')"
if [ -n "$leftover" ]; then
    echo "FAIL: vergil packages present:" >&2
    echo "$leftover" >&2
    exit 1
fi

# vrg-vm create installs vergil-tooling, after it injects the credentials. The
# automated build (scripts/build.sh) creates its VM with limactl and runs
# neither, so an uncredentialed VM has no install to check.
if [ ! -f ~/.config/vergil/app.pem ]; then
    echo "test_vergil: SKIP install checks (not created by vrg-vm create)"
    exit 0
fi

expected="$HOME/.local/bin/vrg-whoami"
resolved="$(command -v vrg-whoami)" || { echo "FAIL: vrg-whoami not on PATH ($PATH)" >&2; exit 1; }
if [ "$resolved" != "$expected" ]; then
    echo "FAIL: vrg-whoami resolves to $resolved, not $expected" >&2
    exit 1
fi
vrg-whoami --mode

echo "test_vergil: all checks passed"
