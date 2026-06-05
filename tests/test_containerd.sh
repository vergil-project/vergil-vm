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

# nerdctl build works end-to-end (issue #97). Base is the already-pulled
# alpine image (no extra network dependency). Asserting the built image
# RUNS — not just that build exited 0 — proves buildkit's OCI-worker
# output actually loaded into the rootless containerd image store.
builddir=$(mktemp -d)
trap 'rm -rf "$builddir"' EXIT
printf '%s\n' \
    'FROM ghcr.io/containerd/alpine:3.14.0' \
    'RUN echo build-works > /buildtest' \
    > "$builddir/Dockerfile"
nerdctl build -t vergil-buildtest "$builddir"
nerdctl images | grep -q vergil-buildtest
nerdctl run --rm vergil-buildtest cat /buildtest | grep -q build-works
# leave the VM clean
nerdctl rmi vergil-buildtest

echo "test_containerd: all checks passed"
