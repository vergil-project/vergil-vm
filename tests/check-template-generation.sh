#!/usr/bin/env bash
# tests/test_template_generation.sh — Assert templates/agent.yaml is the
# current output of scripts/build-template.sh (skel + provision/*.sh).
# HOST-side (no Lima): deliberately NOT named test_*.sh so run-tests.sh does
# not pipe it into a guest. Runs in CI and locally.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${HERE}/.." && pwd)"
if "${REPO_ROOT}/scripts/build-template.sh" --check; then
  echo "PASS: templates/agent.yaml is up to date with the skeleton and provision scripts"
else
  echo "FAIL: templates/agent.yaml is stale — run scripts/build-template.sh and commit the result" >&2
  exit 1
fi
