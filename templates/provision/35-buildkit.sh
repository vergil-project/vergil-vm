#!/bin/bash
# vergil-provision: context=user cadence=boot
set -eux -o pipefail
export PATH="$HOME/.local/bin:/usr/local/bin:$PATH"
XDG_RUNTIME_DIR="/run/user/$(id -u)"
export XDG_RUNTIME_DIR

# install-buildkit-containerd requires the rootless containerd user service to
# exist already (Lima provisions it via its own containerd setup; off-platform
# the cloud-init runcmd does). Wait for it rather than depend on
# provisioning-step ordering.
timeout 300 bash -c 'until systemctl --user is-active --quiet containerd; do sleep 3; done'

# Rootless buildkitd with the CONTAINERD worker in nerdctl's `default`
# namespace (issue #400), not `install-buildkit`'s OCI worker: the OCI worker
# keeps its own content store, so `FROM <locally built image>` is resolved
# against a registry and fails. CONTAINERD_NAMESPACE=default is load-bearing:
# without it the worker reads the `buildkit` namespace and the failure remains.
# This writes default-buildkit.service with the socket
# $XDG_RUNTIME_DIR/buildkit-default/buildkitd.sock, which nerdctl probes first.
# Lima's own containerd setup already installs this same unit; the setuptool
# then skips the existing unit file and starts it only if it is not running.
CONTAINERD_NAMESPACE=default containerd-rootless-setuptool.sh install-buildkit-containerd
