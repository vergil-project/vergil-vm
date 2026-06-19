#!/bin/bash
# scripts/build-template.sh — Assemble templates/agent.yaml from the
# hand-authored skeleton templates/agent.yaml.skel by expanding
# `# @@INCLUDE <repo-relative-path>@@` markers with the named file's content,
# preserving the marker line's indentation. agent.yaml is a GENERATED artifact:
# edit templates/provision/*.sh and templates/agent.yaml.skel, never agent.yaml.
#
# Usage:
#   build-template.sh           # regenerate templates/agent.yaml in place
#   build-template.sh --check    # exit non-zero (with a diff) if agent.yaml is stale
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
SKEL="${REPO_ROOT}/templates/agent.yaml.skel"
OUT="${REPO_ROOT}/templates/agent.yaml"

render() {  # render <skel> -> stdout
  local skel="$1" line indent path
  while IFS= read -r line || [ -n "$line" ]; do
    if [[ "$line" =~ ^([[:space:]]*)#[[:space:]]@@INCLUDE[[:space:]]+([^[:space:]]+)@@[[:space:]]*$ ]]; then
      indent="${BASH_REMATCH[1]}"
      path="${REPO_ROOT}/${BASH_REMATCH[2]}"
      if [ ! -f "$path" ]; then
        echo "build-template: included file not found: ${BASH_REMATCH[2]}" >&2
        exit 1
      fi
      # Prepend the marker's indentation to every included line. Blank lines
      # stay blank (no trailing whitespace).
      while IFS= read -r inc || [ -n "$inc" ]; do
        if [ -z "$inc" ]; then printf '\n'; else printf '%s%s\n' "$indent" "$inc"; fi
      done < "$path"
    else
      printf '%s\n' "$line"
    fi
  done < "$skel"
}

if [ "${1:-}" = "--check" ]; then
  tmp="$(mktemp)"
  trap 'rm -f "$tmp"' EXIT
  render "$SKEL" > "$tmp"
  if ! diff -u "$OUT" "$tmp"; then
    echo "build-template: templates/agent.yaml is stale (see diff above)" >&2
    exit 1
  fi
else
  render "$SKEL" > "$OUT"
  echo "Wrote ${OUT}"
fi
