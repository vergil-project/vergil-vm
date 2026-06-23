#!/usr/bin/env bash
# tests/run-host-tests.sh — Run the host-side (no-Lima) checks: template + cloud-init
# generation freshness, provision manifests, and the OpenTofu interface + validate.
# Safe in CI and on any dev box. (Lima integration stays in scripts/build.sh.)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
for t in check-template-generation check-provision-manifest check-cloud-init-generation \
         check-opentofu-contract check-opentofu-validate check-opentofu-name-validation; do
  echo "== ${t} =="
  bash "${HERE}/${t}.sh"
done
echo "All host-side checks passed."
