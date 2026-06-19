#!/bin/bash
set -eux -o pipefail
PKGS="{{.Param.EXTRA_PACKAGES}}"
PLUGINS="{{.Param.VAGRANT_PLUGINS}}"
NESTED="{{.Param.NESTED_VIRT}}"

WANTED=false
case " ${PKGS} " in *" libvirt-daemon-system "*) WANTED=true ;; esac
case " ${PLUGINS} " in *" vagrant-libvirt "*) WANTED=true ;; esac
if [ "${NESTED}" = "true" ]; then WANTED=true; fi

mkdir -p /etc/vergil
printf '%s\n' "${WANTED}" > /etc/vergil/libvirt-groups.requested

if [ "${WANTED}" = "true" ]; then
  getent group libvirt >/dev/null || groupadd --system libvirt
  getent group kvm >/dev/null || groupadd --system kvm
  usermod -aG libvirt,kvm "{{.User}}"
fi
