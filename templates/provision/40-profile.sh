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
PLUGINS="$VAGRANT_PLUGINS"
if [ -n "$PLUGINS" ]; then
  if ! command -v vagrant >/dev/null 2>&1; then
    if ! command -v gem >/dev/null 2>&1; then
      printf 'ERROR: vagrant_plugins declared but ruby/gem is unavailable — declare ruby-dev (plus gcc, make, pkg-config) in the repo vergil.toml [vm] packages\n' \
        | tee /etc/vergil/provision-error >&2
      exit 1
    fi
    gem install vagrant
  fi
  for _p in $PLUGINS; do
    # Idempotency guard (#177): `vagrant plugin install` contacts
    # gems.hashicorp.com on every invocation, even when the plugin is
    # already present. This block is a cloud-init per-boot runpart, so an
    # unconditional install re-hit the gem source on the cycle-ssh reboot
    # and a transient timeout there aborted the boot under `set -e`
    # (cloud-init status: error → cycle-ssh failed the whole rebuild). The
    # plugin list is read locally from ~/.vagrant.d — no network — so the
    # steady state (plugin already installed) now makes zero network calls.
    if sudo -u "$VERGIL_USER" -H vagrant plugin list 2>/dev/null \
         | grep -q "^${_p} "; then
      continue
    fi
    # Genuine first install. Retry with backoff to ride out a brief gem
    # source hiccup; tolerate the attempts failing (the post-check below is
    # the real gate) so a transient blip warns instead of aborting the boot.
    for _try in 1 2 3; do
      if sudo -u "$VERGIL_USER" -H vagrant plugin install "$_p"; then
        break
      fi
      echo "WARNING: vagrant plugin install '$_p' attempt ${_try}/3 failed; retrying" >&2
      sleep $(( _try * 5 ))
    done
    # A still-absent plugin after the retries is a real failure, not a
    # transient refresh blip — abort loudly rather than ship a VM missing
    # its declared plugin (no-silent-failures).
    if ! sudo -u "$VERGIL_USER" -H vagrant plugin list 2>/dev/null \
          | grep -q "^${_p} "; then
      printf 'ERROR: vagrant plugin "%s" could not be installed after 3 attempts — gems.hashicorp.com unreachable? (declared in the repo vergil.toml [vm] vagrant_plugins)\n' \
        "$_p" | tee /etc/vergil/provision-error >&2
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
