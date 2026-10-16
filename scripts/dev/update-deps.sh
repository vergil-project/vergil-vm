#!/usr/bin/env bash
# scripts/dev/update-deps.sh — vergil-vm's dependency-update hook (epic
# vergil-project/.github#381, spec §6.3). Wired through [dependency-update].hook in
# vergil.toml; vrg-update-deps runs it inside the dev container from the worktree root
# with $VRG_DEPS_REPORT set, after the built-in updaters.
#
#   1. OpenTofu providers: `tofu init -upgrade` per module, within the existing `~>`
#      ranges, refreshing each .terraform.lock.hcl. The OpenTofu registry serves h1:
#      hashes for every platform a provider publishes, so init alone reproduces the
#      committed lockfiles' full platform set (no `tofu providers lock` needed).
#   2. nerdctl: NERDCTL_VERSION in every vm cloud-init.yaml.skel is bumped to the
#      newest stable release within its current major, then cloud-init.yaml is
#      regenerated. A newer major is reported, never bumped.
#   3. Report only: a Lima major above the minimumLimaVersion floor's major, and a Node
#      LTS major above the NodeSource setup_<N>.x major.
#
# Contract: edits files only, never commits. Any failed lookup, parse or tool run exits
# non-zero — there is no silent "no change". Manual run (from the repo root):
#   vrg-container-run -- env VRG_DEPS_REPORT=/workspace/.vergil/deps-report.jsonl \
#     scripts/dev/update-deps.sh
set -euo pipefail
: "${VRG_DEPS_REPORT:?set by vrg-update-deps (export it for a manual run)}"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
# vrg-validate lints without -x, so it cannot follow this source; the lib is linted
# on its own as scripts/dev/update-deps-lib.sh.
# shellcheck disable=SC1091
. "${ROOT}/scripts/dev/update-deps-lib.sh"

# github_release_versions <owner/repo> -> the published (non-draft, non-prerelease)
# release versions, leading "v" stripped, one per line. Fails on a network/HTTP error,
# an unparseable response, or an empty list.
github_release_versions() {
  local json versions
  json="$(curl -fsSL --retry 3 -H 'Accept: application/vnd.github+json' \
    "https://api.github.com/repos/$1/releases?per_page=100")" || return 1
  versions="$(printf '%s' "$json" | python3 -c '
import json, sys
for r in json.load(sys.stdin):
    if not r["draft"] and not r["prerelease"]:
        print(r["tag_name"].removeprefix("v"))
')" || return 1
  [ -n "$versions" ] || { echo "update-deps: no published releases found for $1" >&2; return 1; }
  printf '%s\n' "$versions"
}

# node_lts_major -> the major of the newest Node.js LTS release.
node_lts_major() {
  local json major
  json="$(curl -fsSL --retry 3 https://nodejs.org/dist/index.json)" || return 1
  major="$(printf '%s' "$json" | python3 -c '
import json, sys
lts = [r["version"].removeprefix("v").split(".")[0] for r in json.load(sys.stdin) if r["lts"]]
if not lts:
    sys.exit("update-deps: no LTS release in nodejs.org/dist/index.json")
print(max(lts, key=int))
')" || return 1
  printf '%s\n' "$major"
}

# --- 1. OpenTofu providers, within the existing ~> ranges ----------------------------
modules=("${ROOT}"/opentofu/modules/*/vm "${ROOT}"/opentofu/modules/*/volume)
[ -d "${modules[0]}" ] || { echo "update-deps: no OpenTofu modules under opentofu/modules" >&2; exit 1; }
for m in "${modules[@]}"; do
  echo "update-deps: tofu init -upgrade ${m#"${ROOT}/"}"
  data_dir="$(mktemp -d)"
  TF_DATA_DIR="$data_dir" tofu -chdir="$m" init -backend=false -upgrade -input=false
  rm -rf "$data_dir"
done

# --- 2. nerdctl, within its major; then regenerate cloud-init.yaml -------------------
skels=("${ROOT}"/opentofu/modules/*/vm/cloud-init.yaml.skel)
current=""
for s in "${skels[@]}"; do
  v="$(sed -n -E 's/^[[:space:]]*NERDCTL_VERSION=([0-9]+\.[0-9]+\.[0-9]+)$/\1/p' "$s")"
  [ -n "$v" ] || { echo "update-deps: no NERDCTL_VERSION=x.y.z in ${s#"${ROOT}/"}" >&2; exit 1; }
  if [ -z "$current" ]; then
    current="$v"
  elif [ "$v" != "$current" ]; then
    echo "update-deps: cloud-init skeletons disagree on NERDCTL_VERSION ($current vs $v in ${s#"${ROOT}/"})" >&2
    exit 1
  fi
done
nerdctl_out="$(github_release_versions containerd/nerdctl)"
nerdctl_versions=()
while IFS= read -r v; do nerdctl_versions+=("$v"); done <<<"$nerdctl_out"
nerdctl_latest="$(semver_newest "${nerdctl_versions[@]}")"
target="$(semver_newest_same_major "$current" "${nerdctl_versions[@]}")"
if [ "$target" != "$current" ]; then
  echo "update-deps: nerdctl ${current} -> ${target}"
  for s in "${skels[@]}"; do set_nerdctl_version "$s" "$target"; done
  bash "${ROOT}/scripts/build-cloud-init.sh"
fi
if [ "$(semver_major "$nerdctl_latest")" -gt "$(semver_major "$target")" ]; then
  report_line vergil-vm nerdctl "$target" "$nerdctl_latest" \
    "newer major; bump NERDCTL_VERSION in opentofu/modules/*/vm/cloud-init.yaml.skel deliberately" \
    >> "$VRG_DEPS_REPORT"
fi

# --- 3. Report only: Lima major, Node LTS major --------------------------------------
lima_floor="$(sed -n -E 's/^minimumLimaVersion: "([0-9]+\.[0-9]+\.[0-9]+)"$/\1/p' \
  "${ROOT}/templates/agent.yaml.skel")"
[ -n "$lima_floor" ] || { echo "update-deps: minimumLimaVersion not found in templates/agent.yaml.skel" >&2; exit 1; }
lima_out="$(github_release_versions lima-vm/lima)"
lima_versions=()
while IFS= read -r v; do lima_versions+=("$v"); done <<<"$lima_out"
lima_latest="$(semver_newest "${lima_versions[@]}")"
if [ "$(semver_major "$lima_latest")" -gt "$(semver_major "$lima_floor")" ]; then
  report_line vergil-vm lima "$lima_floor" "$lima_latest" \
    "newer major than minimumLimaVersion in templates/agent.yaml.skel" >> "$VRG_DEPS_REPORT"
fi

node_cur="$(sed -n -E 's|.*https://deb\.nodesource\.com/setup_([0-9]+)\.x.*|\1|p' \
  "${ROOT}/templates/provision/10-base.sh")"
[ "$(printf '%s\n' "$node_cur" | grep -c .)" = 1 ] \
  || { echo "update-deps: expected exactly one setup_<N>.x in templates/provision/10-base.sh, got '${node_cur}'" >&2; exit 1; }
node_lts="$(node_lts_major)"
[[ "$node_lts" =~ ^[0-9]+$ ]] || { echo "update-deps: Node LTS major is not a number: '${node_lts}'" >&2; exit 1; }
if [ "$node_lts" -gt "$node_cur" ]; then
  report_line vergil-vm nodesource "$node_cur" "$node_lts" \
    "newest Node LTS major; setup_${node_cur}.x in templates/provision/10-base.sh" >> "$VRG_DEPS_REPORT"
fi
