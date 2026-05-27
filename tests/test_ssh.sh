#!/bin/bash
# tests/test_ssh.sh — Verify SSH terminal environment forwarding.
set -euo pipefail

CONF="/etc/ssh/sshd_config.d/10-acceptenv-terminal.conf"

# Drop-in config file exists
test -f "$CONF"

# Accepts COLORTERM
grep -q 'AcceptEnv.*COLORTERM' "$CONF"

# Accepts TERM_PROGRAM (trailing space prevents matching only TERM_PROGRAM_VERSION)
grep -q 'AcceptEnv.*TERM_PROGRAM ' "$CONF"

# Accepts TERM_PROGRAM_VERSION
grep -q 'AcceptEnv.*TERM_PROGRAM_VERSION' "$CONF"

echo "test_ssh: all checks passed"
