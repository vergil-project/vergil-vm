#!/usr/bin/env bash
# tests/check-azure-volume-id-parse.sh — Assert the azure/vm module both VALIDATES the
# volume_id as an Azure managed-disk resource ID and PARSES the resource group from index
# 4 of split("/", var.volume_id). Host-side text inspection — no tofu. The check-* prefix
# keeps it out of the run-tests.sh in-guest test_*.sh glob.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

vars="${ROOT}/opentofu/modules/azure/vm/variables.tf"
main="${ROOT}/opentofu/modules/azure/vm/main.tf"

grep -qF 'Microsoft.Compute/disks/' "$vars" \
  || fail "volume_id variable missing the Azure disk resource-ID validation regex"
grep -qE 'resource_group[[:space:]]*=[[:space:]]*local\.id_parts\[4\]' "$main" \
  || fail "main.tf must parse the resource group from local.id_parts[4]"
grep -qF 'split("/", var.volume_id)' "$main" \
  || fail "main.tf must derive id_parts via split(\"/\", var.volume_id)"
echo "PASS: azure/vm parses + validates the volume_id resource ID"
