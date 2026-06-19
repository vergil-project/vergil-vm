#!/usr/bin/env bash
# tests/check-provision-manifest.sh — Validate every templates/provision/*.sh has a
# well-formed `# vergil-provision:` manifest (line 2), and that the skeleton's Lima
# mode for each include is consistent with the script's declared context
# (root -> system/boot, user -> user). HOST-side; check-* prefix keeps it out of the
# run-tests.sh in-guest test_*.sh glob. Runs in CI and locally.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${HERE}/.." && pwd)"
fail() { echo "FAIL: $1" >&2; exit 1; }

for s in "${ROOT}"/templates/provision/*.sh; do
  base="$(basename "$s")"
  m="$(sed -n '2p' "$s")"
  case "$m" in
    "# vergil-provision: "*) : ;;
    *) fail "${base}: missing or misplaced manifest on line 2 (got: ${m})" ;;
  esac
  echo "$m" | grep -Eq 'context=(root|user)' || fail "${base}: bad/absent context"
  echo "$m" | grep -Eq 'cadence=(once|boot)'  || fail "${base}: bad/absent cadence"
  # A 'once' script must name a guard; a 'boot' script must not.
  if echo "$m" | grep -q 'cadence=once'; then
    echo "$m" | grep -q 'guard=' || fail "${base}: cadence=once requires a guard="
  fi
done

# Consistency: a user-context script must be included under a `- mode: user` entry in
# the skeleton; a root-context script under `- mode: system` or `- mode: boot`.
skel="${ROOT}/templates/agent.yaml.skel"
while IFS= read -r incpath; do
  base="$(basename "$incpath")"
  ctx="$(sed -n '2p' "${ROOT}/${incpath}" | grep -oE 'context=(root|user)' | cut -d= -f2)"
  mode="$(awk -v marker="@@INCLUDE ${incpath}@@" '
    /- mode:/ { m=$0 }
    index($0, marker) { print m; exit }' "$skel" | grep -oE 'mode: (system|user|boot)' | awk '{print $2}')"
  case "$ctx:$mode" in
    root:system|root:boot|user:user) : ;;
    *) fail "${base}: context=${ctx} but skel mode=${mode} (inconsistent)" ;;
  esac
done < <(grep -oE 'templates/provision/[^@ ]+\.sh' "$skel")

echo "PASS: all provision manifests valid and consistent with skeleton modes"
