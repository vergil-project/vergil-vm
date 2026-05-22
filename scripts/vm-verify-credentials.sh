#!/bin/bash
# scripts/vm-verify-credentials.sh — Verify credentials inside a VM.
#
# Run inside the VM (via limactl shell or bash -s) after
# vrg-vm-init has injected credentials.
set -euo pipefail

export PATH="$HOME/.local/bin:$PATH"

failures=0

check() {
    local name="$1"
    shift
    printf "  %-35s " "$name"
    if "$@" > /dev/null 2>&1; then
        echo "OK"
    else
        echo "FAIL"
        failures=$((failures + 1))
    fi
}

echo "Verifying credentials..."

check "App private key" test -f ~/.config/vergil/app.pem
check "App private key permissions" test "$(stat -c '%a' ~/.config/vergil/app.pem 2>/dev/null || stat -f '%Lp' ~/.config/vergil/app.pem)" = "600"
check "App config" test -f ~/.config/vergil/app.env
check "App config permissions" test "$(stat -c '%a' ~/.config/vergil/app.env 2>/dev/null || stat -f '%Lp' ~/.config/vergil/app.env)" = "600"
check "Git HTTPS rewrite" git config --global url.https://github.com/.insteadOf

total=5
echo ""
echo "Credential checks: $((total - failures))/${total} passed"
exit "$failures"
