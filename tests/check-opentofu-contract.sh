#!/usr/bin/env bash
# tests/check-opentofu-contract.sh — Assert each provider's volume/vm modules declare
# exactly the variable/output names in opentofu/interface.json. This is the
# provider-agnostic guard: Azure (Phase 3) must satisfy the same contract. HOST-side,
# no tofu needed (text inspection of *.tf). check-* prefix keeps it out of the
# run-tests.sh in-guest test_*.sh glob.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
IFACE="${ROOT}/opentofu/interface.json"
fail() { echo "FAIL: $1" >&2; exit 1; }
command -v jq >/dev/null || fail "jq required"

# Providers present under opentofu/modules/. Azure is added in Phase 3; the test
# covers whatever provider dirs exist.
shopt -s nullglob
pdirs=("${ROOT}"/opentofu/modules/*/)
[ "${#pdirs[@]}" -gt 0 ] || fail "no provider module dirs under opentofu/modules/"
for pdir in "${pdirs[@]}"; do
  provider="$(basename "$pdir")"
  for kind in volume vm; do
    mdir="${pdir}${kind}"
    [ -d "$mdir" ] || fail "${provider}/${kind}: module dir missing"
    # Declared names from the .tf (block label is the 2nd token: variable "x" {).
    declared_vars="$(grep -hoE '^variable[[:space:]]+"[^"]+"' "${mdir}"/*.tf | sed -E 's/.*"([^"]+)"/\1/' | sort -u)"
    declared_outs="$(grep -hoE '^output[[:space:]]+"[^"]+"'   "${mdir}"/*.tf | sed -E 's/.*"([^"]+)"/\1/' | sort -u)"
    want_vars="$(jq -r ".${kind}.variables[]" "$IFACE" | sort -u)"
    want_outs="$(jq -r ".${kind}.outputs[]"   "$IFACE" | sort -u)"
    [ "$declared_vars" = "$want_vars" ] || fail "${provider}/${kind}: variables mismatch
--- want ---
${want_vars}
--- got ---
${declared_vars}"
    [ "$declared_outs" = "$want_outs" ] || fail "${provider}/${kind}: outputs mismatch
--- want ---
${want_outs}
--- got ---
${declared_outs}"
  done
done
echo "PASS: all modules satisfy opentofu/interface.json"
