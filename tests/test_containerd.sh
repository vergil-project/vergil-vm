#!/bin/bash
# tests/test_containerd.sh — Verify rootless containerd is running
# and nerdctl is functional.
set -euo pipefail

# containerd is running as a user service
systemctl --user is-active containerd

# nerdctl is available
command -v nerdctl

# nerdctl can query the runtime
nerdctl info > /dev/null

# nerdctl can pull and run a minimal container
nerdctl pull --quiet ghcr.io/containerd/alpine:3.14.0
nerdctl run --rm ghcr.io/containerd/alpine:3.14.0 echo "container works"

echo "test_containerd: all checks passed"
