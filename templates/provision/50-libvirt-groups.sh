#!/bin/bash
# vergil-provision: context=root cadence=boot
set -eux -o pipefail
# Backend-neutral inputs (#199): Lima/cloud each write this file their own way.
. /etc/vergil/provision.env
PKGS="$EXTRA_PACKAGES"
PLUGINS="$VAGRANT_PLUGINS"
NESTED="$NESTED_VIRT"

WANTED=false
case " ${PKGS} " in *" libvirt-daemon-system "*) WANTED=true ;; esac
case " ${PLUGINS} " in *" vagrant-libvirt "*) WANTED=true ;; esac
if [ "${NESTED}" = "true" ]; then WANTED=true; fi

mkdir -p /etc/vergil
printf '%s\n' "${WANTED}" > /etc/vergil/libvirt-groups.requested

if [ "${WANTED}" = "true" ]; then
  getent group libvirt >/dev/null || groupadd --system libvirt
  getent group kvm >/dev/null || groupadd --system kvm
  usermod -aG libvirt,kvm "$VERGIL_USER"
fi
