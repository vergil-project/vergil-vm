#!/bin/bash
# vergil-provision: context=user cadence=boot
set -eux -o pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
export XDG_RUNTIME_DIR="/run/user/$(id -u)"

# install-buildkit requires the rootless containerd user service to exist
# already (Lima provisions it via its own containerd setup). Wait for it
# rather than depend on provisioning-step ordering.
timeout 300 bash -c 'until systemctl --user is-active --quiet containerd; do sleep 3; done'

containerd-rootless-setuptool.sh install-buildkit
