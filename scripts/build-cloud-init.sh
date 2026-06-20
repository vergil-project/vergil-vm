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
  local s b ctx
  for s in "${PROV}"/*.sh; do
    b="$(basename "$s")"
    ctx="$(context_of "$s")"
    if [ "$ctx" = "user" ]; then
      printf "  - bash -c '. /etc/vergil/provision.env && sudo -iu \"\$VERGIL_USER\" bash /opt/vergil/provision/%s'\n" "$b"
    else
      printf '  - bash /opt/vergil/provision/%s\n' "$b"
    fi
  done
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
