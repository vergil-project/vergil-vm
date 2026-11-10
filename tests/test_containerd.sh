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

# The buildkitd nerdctl uses is the rootless containerd worker in namespace
# `default` (issue #400): nerdctl probes buildkit-default/ first, and only that
# worker reads nerdctl's image store. The bracket stops pgrep matching itself.
test -S "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/buildkit-default/buildkitd.sock"
pgrep -f "[b]uildkitd .*--containerd-worker=true .*--containerd-worker-namespace=default" > /dev/null

# nerdctl build works end-to-end (issue #97). Base is the already-pulled
# alpine image (no extra network dependency). Asserting the built image
# RUNS — not just that build exited 0 — proves buildkit's output is in the
# rootless containerd image store.
builddir=$(mktemp -d)
childdir=$(mktemp -d)
trap 'rm -rf "$builddir" "$childdir"' EXIT
printf '%s\n' \
    'FROM ghcr.io/containerd/alpine:3.14.0' \
    'RUN echo build-works > /buildtest' \
    > "$builddir/Dockerfile"
nerdctl build -t vergil-buildtest "$builddir"
nerdctl images | grep -q vergil-buildtest
nerdctl run --rm vergil-buildtest cat /buildtest | grep -q build-works

# A build can use a locally built image as its parent, with no registry
# involved (issue #400). An OCI-worker buildkitd resolves the local tag
# against docker.io and fails with "pull access denied".
printf '%s\n' \
    'FROM vergil-buildtest' \
    'RUN echo chained-works > /chaintest' \
    > "$childdir/Dockerfile"
nerdctl build -t vergil-buildtest-child "$childdir"
nerdctl run --rm vergil-buildtest-child cat /buildtest /chaintest > "$childdir/out"
grep -qx build-works "$childdir/out"
grep -qx chained-works "$childdir/out"

# leave the VM clean
nerdctl rmi vergil-buildtest-child vergil-buildtest

echo "test_containerd: all checks passed"
