#!/usr/bin/env bash
# tests/run-host-tests.sh — Run the host-side (no-Lima) checks: template + cloud-init
# generation freshness, provision manifests, the OpenTofu interface + validate, and
# test_base.sh's shell-rc assertions against the provisioned rc files.
# Safe in CI and on any dev box. (Lima integration stays in scripts/build.sh.)
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
# The list between the markers is kept in step with scripts/bin/validate-custom's
# step 1 list; tests/check-host-check-lists.sh fails when they differ. One name per line.
# --- BEGIN host-checks ---
host_checks=(
  check-template-generation
  check-provision-manifest
  check-cloud-init-generation
  check-azure-volume-id-parse
  check-rootless-userns
  check-opentofu-contract
  check-opentofu-validate
  check-opentofu-name-validation
  check-update-deps-hook
  check-vm-init-series
  check-vagrant-plugins
  check-test-base
  check-host-check-lists
)
# --- END host-checks ---
for t in "${host_checks[@]}"; do
  echo "== ${t} =="
  bash "${HERE}/${t}.sh"
done
echo "All host-side checks passed."
