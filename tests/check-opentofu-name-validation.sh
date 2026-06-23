#!/usr/bin/env bash
# tests/check-opentofu-name-validation.sh — Assert each GCP module's `name` variable
# carries the defense-in-depth validation backing the hashed-naming contract (#242):
# RFC1035 charset and length <= 58 (so the derived <name>-data disk stays within GCP's
# 63-char limit). HOST-side text inspection — no tofu needed. The check-* prefix keeps
# it out of the run-tests.sh in-guest test_*.sh glob.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

for kind in volume vm; do
  f="${ROOT}/opentofu/modules/gcp/${kind}/variables.tf"
  [ -f "$f" ] || fail "${kind}: ${f#"${ROOT}"/} missing"
  grep -qF 'length(var.name) <= 58' "$f" \
    || fail "${kind}: name variable missing length validation 'length(var.name) <= 58'"
  grep -qF 'can(regex("^[a-z]([-a-z0-9]*[a-z0-9])?$", var.name))' "$f" \
    || fail "${kind}: name variable missing RFC1035 charset validation"
done
echo "PASS: GCP volume/vm name validation present"
