#!/bin/bash
# vergil-provision: context=root cadence=once guard=provisioned.profile
set -eux -o pipefail
# Backend-neutral inputs (#199): Lima/cloud each write this file their own way.
. /etc/vergil/provision.env
export DEBIAN_FRONTEND=noninteractive

# First-boot-only (#177): skip the per-repo profile install (apt repos,
# extra packages, vagrant plugins) on every boot after the first. Marker
# stamped LAST so a failed install re-runs next boot.
if [ -f /etc/vergil/provisioned.profile ]; then exit 0; fi

mkdir -p /etc/vergil
printf '%s\n' "$SPEC_FINGERPRINT" > /etc/vergil/vm-spec.fingerprint

# Extra apt repositories: each record is "name|key_url|uri|suite|components";
# records are ";"-separated. Keys are expected ASCII-armored (gpg --dearmor).
REPOS="$APT_REPOS"
if [ -n "$REPOS" ]; then
  IFS=';' read -ra _repos <<< "$REPOS"
  for _r in "${_repos[@]}"; do
    IFS='|' read -r _name _key _uri _suite _comp <<< "$_r"
    curl -fsSL "$_key" | gpg --dearmor -o "/usr/share/keyrings/${_name}.gpg"
    echo "deb [signed-by=/usr/share/keyrings/${_name}.gpg] $_uri $_suite $_comp" \
      > "/etc/apt/sources.list.d/${_name}.list"
  done
fi

PKGS="$EXTRA_PACKAGES"
if [ -n "$PKGS" ]; then
  apt-get update
  # Per-package resolution diagnostics (issue #130): apt transactions are
  # all-or-nothing, so a single uninstallable package zeroes the WHOLE
  # extra-package layer and the real cause drowns in apt output (vagrant
  # on arm64 took down 13 installable packages with it). Check every
  # declared package has an installation candidate for this architecture
  # first, and fail naming exactly the offenders. The error lands in
  # /etc/vergil/provision-error, which the readiness probe's hint names.
  MISSING=""
  for _pkg in $PKGS; do
    if [ -z "$(apt-cache madison "$_pkg")" ]; then
      MISSING="${MISSING} ${_pkg}"
    fi
  done
  if [ -n "$MISSING" ]; then
    printf 'ERROR: no installation candidate on %s for:%s (declared in the repo vergil.toml [vm] packages)\n' \
      "$(dpkg --print-architecture)" "${MISSING}" \
      | tee /etc/vergil/provision-error >&2
    exit 1
  fi
  # shellcheck disable=SC2086  # word-splitting the package list is intended
  apt-get install -y --no-install-recommends $PKGS
fi

# Vagrant plugins compile native extensions (build deps come via EXTRA_PACKAGES)
# and must belong to the Lima user who runs vagrant, not root. `sudo -u … -H`
# points HOME at the user so plugins land in their ~/.vagrant.d.
#
# The template owns the vagrant binary itself (issue #130): vagrant has no
# apt installation candidate on arm64 from ANY source — HashiCorp's repo
# publishes no arm64 vagrant, and noble dropped it from universe post-BUSL
# — so the only supported Linux/arm64 path is HashiCorp's Ruby gem.
# Consuming repos declare plugins plus the build deps (ruby-dev, gcc,
# make, pkg-config) in packages; "vagrant" never belongs in the apt list.
#
# --- BEGIN vagrant-plugin-helpers (unit-checked by tests/check-vagrant-plugins.sh) ---
PROVISION_ERROR=/etc/vergil/provision-error

# racc seed (#346). vagrant-libvirt needs nokogiri, which needs racc. Ruby 3.3
# (Ubuntu 26.04) ships racc as a *bundled* gem, no longer a *default* one, and
# vagrant 2.4.x mishandles that: the install resolves racc to the system copy,
# so it never lands in ~/.vagrant.d/gems, and vagrant's offline re-check (run
# right after the install and on every later start) sees only default gems
# plus that plugin dir, so it fails with "'nokogiri (~> 1.6)' requires
# 'racc (~> 1.4)'". Installing racc as a plugin at a version the system does
# NOT have forces a real download into the plugin dir. The pin must stay newer
# than every racc the distro Ruby ships; vagrant_racc_seed_check enforces that
# loudly. To update: bump to the newest racc on rubygems.org.
VAGRANT_RACC_SEED=1.8.1

# Fail unless every system racc is older than the seed — an equal or newer
# system copy would win resolution and the seed would never reach the plugin dir.
vagrant_racc_seed_check() {
  local _sys
  _sys="$(ruby -e 'puts Gem::Specification.find_all_by_name("racc").map(&:version).max')"
  if [ -n "$_sys" ] && ruby -e 'exit(Gem::Version.new(ARGV[0]) >= Gem::Version.new(ARGV[1]) ? 0 : 1)' \
       "$_sys" "$VAGRANT_RACC_SEED"; then
    printf 'ERROR: system racc %s is not older than the vagrant racc seed %s — bump VAGRANT_RACC_SEED in templates/provision/40-profile.sh to a newer racc release (#346)\n' \
      "$_sys" "$VAGRANT_RACC_SEED" | tee "$PROVISION_ERROR" >&2
    exit 1
  fi
}

# vagrant_plugin_install <name> [install args…] — install one plugin for the
# Lima user. A dependency-resolution error is deterministic, so it fails at
# once with vagrant's own message; anything else is retried with backoff to
# ride out a brief gem-source hiccup, then fails naming the last error.
vagrant_plugin_install() {
  local _name="$1" _out _msg _try
  shift
  _out="$(mktemp)"
  for _try in 1 2 3; do
    if sudo -u "$VERGIL_USER" -H vagrant plugin install "$_name" "$@" 2>&1 | tee "$_out"; then
      rm -f "$_out"
      return 0
    fi
    _msg="$(grep -m1 -E "Unable to resolve dependency|conflicting dependencies|Unable to activate" "$_out" || true)"
    if [ -n "$_msg" ]; then
      printf 'ERROR: vagrant plugin "%s" failed dependency resolution (not retried — it is deterministic): %s\n' \
        "$_name" "$(echo "$_msg" | sed 's/^[[:space:]]*//')" | tee "$PROVISION_ERROR" >&2
      rm -f "$_out"
      exit 1
    fi
    echo "WARNING: vagrant plugin install '$_name' attempt ${_try}/3 failed; retrying" >&2
    sleep $(( _try * 5 ))
  done
  _msg="$(grep -v '^[[:space:]]*$' "$_out" | tail -n 1)"
  printf 'ERROR: vagrant plugin "%s" could not be installed after 3 attempts; last error: %s\n' \
    "$_name" "${_msg:-<no output>}" | tee "$PROVISION_ERROR" >&2
  rm -f "$_out"
  exit 1
}

# vagrant_plugin_listed <name> — the plugin list is read locally from
# ~/.vagrant.d, no network (#177).
vagrant_plugin_listed() {
  sudo -u "$VERGIL_USER" -H vagrant plugin list 2>/dev/null | grep -q "^$1 "
}
# --- END vagrant-plugin-helpers ---

PLUGINS="$VAGRANT_PLUGINS"
if [ -n "$PLUGINS" ]; then
  if ! command -v vagrant >/dev/null 2>&1; then
    if ! command -v gem >/dev/null 2>&1; then
      printf 'ERROR: vagrant_plugins declared but ruby/gem is unavailable — declare ruby-dev (plus build-essential, pkg-config) in the repo vergil.toml [vm] packages\n' \
        | tee /etc/vergil/provision-error >&2
      exit 1
    fi
    # The vagrant gem compiles native extensions, so a complete C toolchain must be
    # present. Trap the failure and name it (#244) — a bare `gem install` left no
    # provision-error, so a missing build dep buried itself in raw gem output. The
    # usual culprit on a minimal base is no libc6-dev (declare build-essential).
    if ! gem install vagrant; then
      printf 'ERROR: "gem install vagrant" failed to build its native extensions — declare build-essential (gcc/g++/make/libc6-dev) in the repo vergil.toml [vm] packages; the minimal cloud base ships no libc6-dev, so a "stdio.h: No such file" compile error here means the C toolchain is incomplete\n' \
        | tee /etc/vergil/provision-error >&2
      exit 1
    fi
  fi
  # Seed racc ahead of vagrant-libvirt (see VAGRANT_RACC_SEED above).
  case " ${PLUGINS} " in
    *" vagrant-libvirt "*)
      if ! vagrant_plugin_listed racc; then
        vagrant_racc_seed_check
        vagrant_plugin_install racc --plugin-version "$VAGRANT_RACC_SEED"
      fi
      ;;
  esac
  for _p in $PLUGINS; do
    # Idempotency guard (#177): `vagrant plugin install` contacts
    # gems.hashicorp.com on every invocation, even when the plugin is
    # already present. This block is a cloud-init per-boot runpart, so an
    # unconditional install re-hit the gem source on the cycle-ssh reboot
    # and a transient timeout there aborted the boot under `set -e`
    # (cloud-init status: error → cycle-ssh failed the whole rebuild). The
    # plugin list is read locally from ~/.vagrant.d — no network — so the
    # steady state (plugin already installed) now makes zero network calls.
    if vagrant_plugin_listed "$_p"; then
      continue
    fi
    vagrant_plugin_install "$_p"
    # An install that exits 0 but leaves the plugin unlisted (or vagrant
    # unable to start) is a real failure — abort loudly rather than ship a VM
    # missing its declared plugin (no-silent-failures).
    if ! vagrant_plugin_listed "$_p"; then
      printf 'ERROR: vagrant plugin "%s" installed but is not listed by "vagrant plugin list": %s (declared in the repo vergil.toml [vm] vagrant_plugins)\n' \
        "$_p" "$(sudo -u "$VERGIL_USER" -H vagrant plugin list 2>&1 | grep -v '^[[:space:]]*$' | tail -n 1)" \
        | tee "$PROVISION_ERROR" >&2
      exit 1
    fi
  done
fi

# Keep the apt lists cache (see the base-tools step): the wipe only forced
# a full re-download on the next boot (#177).
apt-get clean

# Stamp the profile completion marker LAST, only after the install above
# succeeded (#177).
touch /etc/vergil/provisioned.profile
