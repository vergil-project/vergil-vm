#!/bin/bash
# scripts/build-cloud-init.sh — Assemble opentofu/modules/gcp/vm/cloud-init.yaml from
# cloud-init.yaml.skel + templates/provision/*.sh. Expands:
#   @@PROVISION_FILES@@  -> a write_files entry per script (to /opt/vergil/provision/)
#   @@PROVISION_RUNCMD@@ -> an ordered runcmd line per script, context-mapped
#     (manifest context=root -> bash <script>; context=user -> source provision.env then
#      sudo -iu "$VERGIL_USER" bash <script>)
# The @@PROVISION_ENV@@ sentinel is left intact: the vm module fills it at apply time
# via replace() (NOT templatefile, which would try to interpret the shell ${...} the
# inlined provision scripts contain).
# Usage: build-cloud-init.sh [--check]
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKEL="${ROOT}/opentofu/modules/gcp/vm/cloud-init.yaml.skel"
OUT="${ROOT}/opentofu/modules/gcp/vm/cloud-init.yaml"
PROV="${ROOT}/templates/provision"

context_of() { # context_of <script> -> root|user
  sed -n '2p' "$1" | grep -oE 'context=(root|user)' | cut -d= -f2
}

emit_files() {
  local s b ln
  for s in "${PROV}"/*.sh; do
    b="$(basename "$s")"
    printf '  - path: /opt/vergil/provision/%s\n    permissions: '\''0755'\''\n    content: |\n' "$b"
    # Indent each line 6 spaces under `content: |`; keep blank lines blank (no
    # trailing whitespace), matching scripts/build-template.sh.
    while IFS= read -r ln || [ -n "$ln" ]; do
      if [ -z "$ln" ]; then printf '\n'; else printf '      %s\n' "$ln"; fi
    done < "$s"
  done
}

emit_runcmd() {
  # ONE fail-fast runcmd entry (#244): `set -e` so the FIRST failing provision script
  # aborts the whole run -> cloud-init status: error -> await-readiness fails loudly,
  # instead of cloud-init silently continuing past a failure and reporting a
  # half-provisioned VM as ready. Each script is bracketed with START/DONE markers
  # (#243) so the failing one is obvious in cloud-init-output.log — DONE prints only on
  # success, so the last START with no matching DONE pinpoints the failure. User-context
  # scripts run in a subshell (not a nested `bash -c '…'`) to keep the outer entry
  # single-quoted with no embedded single quotes.
  local s b ctx
  printf "  - bash -c 'set -e"
  for s in "${PROV}"/*.sh; do
    b="$(basename "$s")"
    ctx="$(context_of "$s")"
    printf '; echo "=== provision %s (%s) START ===" >&2' "$b" "$ctx"
    if [ "$ctx" = "user" ]; then
      # shellcheck disable=SC2016  # $VERGIL_USER must stay literal — expanded on the VM, not here
      printf '; ( . /etc/vergil/provision.env && sudo -iu "$VERGIL_USER" bash /opt/vergil/provision/%s )' "$b"
    else
      printf '; bash /opt/vergil/provision/%s' "$b"
    fi
    printf '; echo "=== provision %s DONE ===" >&2' "$b"
  done
  printf "'\n"
}

render() {
  while IFS= read -r line || [ -n "$line" ]; do
    case "$line" in
      *"@@PROVISION_FILES@@"*) emit_files ;;
      *"@@PROVISION_RUNCMD@@"*) emit_runcmd ;;
      *) printf '%s\n' "$line" ;;
    esac
  done < "$SKEL"
}

if [ "${1:-}" = "--check" ]; then
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  render > "$tmp"
  if ! diff -u "$OUT" "$tmp"; then
    echo "build-cloud-init: cloud-init.yaml is stale (run scripts/build-cloud-init.sh and commit)" >&2
    exit 1
  fi
else
  render > "$OUT"
  echo "Wrote ${OUT}"
fi
