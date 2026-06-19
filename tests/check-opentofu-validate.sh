#!/usr/bin/env bash
# tests/check-opentofu-validate.sh — fmt-check + init(-backend=false) + validate every
# OpenTofu module. Visible SKIP if tofu is not installed (no silent pass). HOST-side;
# check-* prefix keeps it out of the run-tests.sh in-guest glob.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
if ! command -v tofu >/dev/null 2>&1; then
  echo "SKIP (tofu not installed; install OpenTofu >=1.8 to exercise module validation)"
  exit 0
fi
rc=0
shopt -s nullglob
for m in "${ROOT}"/opentofu/modules/*/volume "${ROOT}"/opentofu/modules/*/vm; do
  [ -d "$m" ] || continue
  echo "== ${m#"${ROOT}"/} =="
  ( cd "$m" && tofu fmt -check -diff && tofu init -backend=false -input=false >/dev/null && tofu validate ) || rc=1
done
if [ "$rc" -eq 0 ]; then
  echo "PASS: all modules fmt-clean and valid"
else
  echo "FAIL: see above" >&2
  exit 1
fi
