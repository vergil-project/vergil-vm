#!/usr/bin/env bash
# tests/e2e-port-forwards.sh — End-to-end port-forward relay build (issue #170).
#
# Builds a profile VM declaring a single port_forwards entry and asserts the
# full data path the feature promises:
#
#   Mac localhost:<port> -> (Lima auto-forward) -> VM 0.0.0.0:<port>
#     -> (systemd-socket-proxyd) -> <to>
#
# The "<to>" target is a throwaway HTTP listener started INSIDE the VM on a
# loopback port, standing in for the nested libvirt guest the feature really
# serves — so the test needs no nested virt and stays CI-light. The relay's
# 0.0.0.0 bind is what triggers Lima's default port-forwarding; we verify the
# Mac's localhost reaches the listener through the relay with no Lima config
# change. This is a HOST-side script (it runs limactl + curls the host), so it
# is deliberately NOT named test_*.sh — run-tests.sh must not pipe it into a
# guest. It manages its own throwaway instance.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
TEMPLATE="${HERE}/../templates/agent.yaml"
INSTANCE="vergil-portforward-e2e"
VM_PORT=13000          # exposed on the VM and (via Lima auto-forward) the Mac
TARGET_PORT=19000      # in-VM loopback listener standing in for a nested guest
TARGET="127.0.0.1:${TARGET_PORT}"
UNIT="vergil-portforward-${VM_PORT}"

cleanup() {
  limactl delete --force "${INSTANCE}" >/dev/null 2>&1 || true
}
trap cleanup EXIT

fail() {
  echo "FAIL: $1" >&2
  exit 1
}

limactl create --name="${INSTANCE}" --tty=false \
  --set=".param.PORT_FORWARDS = \"${VM_PORT}|${TARGET}\"" \
  "${TEMPLATE}"
limactl start "${INSTANCE}" --tty=false

# 1. The relay socket unit is active and bound on 0.0.0.0:<port> in the VM.
#    The 0.0.0.0 bind is the precondition for Lima's auto-forward.
limactl shell "${INSTANCE}" -- systemctl is-active --quiet "${UNIT}.socket" \
  || fail "relay socket ${UNIT}.socket is not active"
limactl shell "${INSTANCE}" -- ss -ltn \
  | grep -q "0.0.0.0:${VM_PORT}" \
  || fail "relay is not listening on 0.0.0.0:${VM_PORT} in the VM"

# 2. The relay's proxy target matches what was declared.
limactl shell "${INSTANCE}" -- grep -q "systemd-socket-proxyd ${TARGET}" \
  "/etc/systemd/system/${UNIT}.service" \
  || fail "relay service does not proxy to ${TARGET}"

# 3. Stand up the stand-in "nested guest": a detached HTTP listener on the VM's
#    loopback target port. setsid+nohup so it outlives this shell channel.
limactl shell "${INSTANCE}" -- bash -c \
  "setsid nohup python3 -m http.server ${TARGET_PORT} --bind 127.0.0.1 \
     >/tmp/pf-listener.log 2>&1 < /dev/null &" \
  || fail "could not start in-VM test listener"

# Wait for the in-VM listener to answer through the relay locally first, so a
# host-side failure later is unambiguously about the Lima forward, not the
# listener still warming up.
for _ in $(seq 1 30); do
  if limactl shell "${INSTANCE}" -- \
       curl -fsS -o /dev/null "http://127.0.0.1:${VM_PORT}/"; then
    relay_ok=1
    break
  fi
  sleep 1
done
[ "${relay_ok:-0}" = 1 ] \
  || fail "relay did not reach the in-VM listener on :${VM_PORT}"

# 4. The whole path: the Mac's localhost reaches the listener via Lima's
#    auto-forward of the relay's 0.0.0.0 bind — no Lima portForwards config.
for _ in $(seq 1 30); do
  if curl -fsS -o /dev/null "http://127.0.0.1:${VM_PORT}/"; then
    host_ok=1
    break
  fi
  sleep 1
done
[ "${host_ok:-0}" = 1 ] \
  || fail "host localhost:${VM_PORT} did not reach the relay via Lima auto-forward"

echo "PASS: port-forward relay end-to-end (socket bind + proxy target + host auto-forward reachability)"
