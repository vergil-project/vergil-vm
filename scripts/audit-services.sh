#!/bin/bash
# scripts/audit-services.sh — Dump the VM's systemd inventory (qualitative).
#
# Host-side wrapper: concatenates the shared in-guest snippet with a call to
# inv_dump_lists and pipes it into the VM. Output is paste-ready for issue #78
# and the first diagnostic when something later breaks.
#
# Usage: ./scripts/audit-services.sh [instance]   (default: vergil-agent-test)
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="${SCRIPT_DIR}/../tests/lib/inventory.sh"
INSTANCE="${1:-vergil-agent-test}"

{ cat "$LIB"; echo 'inv_dump_lists'; } | limactl shell "$INSTANCE" -- bash -s
