#!/bin/bash
# scripts/vm-metrics.sh — Labeled before/after footprint snapshot.
#
# Host-side wrapper. Records the VM's resource config in the header so
# before/after parity is self-evident on the face of the snapshot.
#
# Usage: ./scripts/vm-metrics.sh <before|after> [instance]
#   (default instance: vergil-agent-test)
set -euo pipefail

LABEL="${1:?Usage: vm-metrics.sh <before|after> [instance]}"
INSTANCE="${2:-vergil-agent-test}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
LIB="${SCRIPT_DIR}/../tests/lib/inventory.sh"

# Resource config (parity check) — Lima reports memory/disk in bytes.
cfg=$(limactl list --json "$INSTANCE" \
  | jq -r '"cpus=\(.cpus) memory_bytes=\(.memory) disk_bytes=\(.disk)"')

echo "=== vm-metrics [$LABEL] ==="
echo "instance=$INSTANCE"
echo "config: $cfg"
echo "---"
{ cat "$LIB"; echo 'inv_metrics_block'; } | limactl shell "$INSTANCE" -- bash -s
echo "=== end [$LABEL] ==="
