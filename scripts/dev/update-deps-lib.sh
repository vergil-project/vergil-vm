#!/usr/bin/env bash
# scripts/dev/update-deps-lib.sh — pure helpers for scripts/dev/update-deps.sh
# (epic vergil-project/.github#381). Sourced, never executed. No network, no tofu.
# Every helper fails (non-zero) rather than printing an empty or unchanged result.

# semver_major <x.y.z> -> x
semver_major() { printf '%s\n' "${1%%.*}"; }

# _semver_sorted <version>... -> the stable x.y.z versions, ascending (numeric order).
# Pre-releases and anything else that is not exactly x.y.z are dropped.
_semver_sorted() {
  printf '%s\n' "$@" | grep -E '^[0-9]+\.[0-9]+\.[0-9]+$' | sort -t. -k1,1n -k2,2n -k3,3n
}

# semver_newest <version>... -> the newest stable x.y.z. Fails when there is none.
semver_newest() {
  local newest
  newest="$(_semver_sorted "$@" | tail -1)"
  [ -n "$newest" ] || { echo "update-deps: no stable x.y.z version among: $*" >&2; return 1; }
  printf '%s\n' "$newest"
}

# semver_newest_same_major <current> <candidate>... -> the newest stable x.y.z sharing
# current's major (current itself if nothing newer in that major).
semver_newest_same_major() {
  local cur="$1"; shift
  local major; major="$(semver_major "$cur")"
  local v same=()
  for v in "$cur" "$@"; do
    [ "$(semver_major "$v")" = "$major" ] && same+=("$v")
  done
  semver_newest "${same[@]}"
}

# set_nerdctl_version <file> <version> — rewrite the NERDCTL_VERSION=x.y.z assignment
# only. Fails if the file has no such assignment or it did not take.
set_nerdctl_version() {
  local file="$1" version="$2"
  grep -qE '^[[:space:]]*NERDCTL_VERSION=[0-9]+\.[0-9]+\.[0-9]+$' "$file" \
    || { echo "update-deps: no NERDCTL_VERSION=x.y.z line in $file" >&2; return 1; }
  sed -i.bak -E "s/^([[:space:]]*NERDCTL_VERSION=)[0-9]+\.[0-9]+\.[0-9]+$/\1${version}/" "$file"
  rm -f "$file.bak"
  grep -qE "^[[:space:]]*NERDCTL_VERSION=${version//./\\.}$" "$file" \
    || { echo "update-deps: failed to set NERDCTL_VERSION=${version} in $file" >&2; return 1; }
}

# report_line <source> <name> <current> <latest> [note] — one held-back JSON line in the
# vergil-tooling report format (spec §7.2), properly JSON-escaped.
report_line() {
  python3 -c '
import json, sys
keys = ("source", "name", "current", "latest", "note")
print(json.dumps(dict(zip(keys, sys.argv[1:]))))
' "$@"
}
