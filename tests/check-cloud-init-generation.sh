#!/usr/bin/env bash
# tests/check-cloud-init-generation.sh — Assert the committed gcp vm cloud-init.yaml is
# the current output of scripts/build-cloud-init.sh (skeleton + templates/provision/*.sh).
# HOST-side, no tofu. check-* prefix keeps it out of the run-tests.sh in-guest glob.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
if "${ROOT}/scripts/build-cloud-init.sh" --check; then
  echo "PASS: gcp vm cloud-init.yaml is up to date with provision scripts"
else
  echo "FAIL: cloud-init.yaml stale — run scripts/build-cloud-init.sh and commit" >&2
  exit 1
fi
