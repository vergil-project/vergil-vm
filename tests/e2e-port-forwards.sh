#!/usr/bin/env bash
# tests/e2e-port-forwards.sh — End-to-end port-forward relay build (issue #170).
#
# Builds a profile VM declaring a single port_forwards entry and asserts the
# full data path the feature promises:
#
#   Mac localhost:<port> -> (Lima auto-forward) -> VM 0.0.0.0:<port>
#     -> (socat relay) -> <to>
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

# Resolve the template's HOST_PROJECTS_DIR mount to an absolute path: limactl 2.1.1
# rejects a non-absolute mount location as fatal. This throwaway VM does not use
# /projects, so any valid absolute dir (the test tree here) satisfies the validator.
limactl create --name="${INSTANCE}" --tty=false \
  --set=".mounts[0].location = \"${HERE}\"" \
  --set=".param.PORT_FORWARDS = \"${VM_PORT}|${TARGET}\"" \
  "${TEMPLATE}"
limactl start "${INSTANCE}" --tty=false

# 1. The relay service unit is active and bound on 0.0.0.0:<port> in the VM.
#    socat binds the listener directly (no socket-activation unit); that 0.0.0.0
#    bind is the precondition for Lima's auto-forward.
limactl shell "${INSTANCE}" -- systemctl is-active --quiet "${UNIT}.service" \
  || fail "relay service ${UNIT}.service is not active"
limactl shell "${INSTANCE}" -- ss -ltn \
  | grep -q "0.0.0.0:${VM_PORT}" \
  || fail "relay is not listening on 0.0.0.0:${VM_PORT} in the VM"

# 2. The relay proxies to the declared target via socat, and carries the -T
#    idle-timeout that reaps half-dead connections (issue #298 — the leak fix).
limactl shell "${INSTANCE}" -- grep -qE "/socat -T [0-9]+ .* TCP:${TARGET}\$" \
  "/etc/systemd/system/${UNIT}.service" \
  || fail "relay service does not run 'socat -T <n> ... TCP:${TARGET}'"

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

# 5. Downstream-restart resilience (issue #192). Assert the relay recovers on
#    its own — no manual relay restart — after the downstream it proxies to is
#    bounced. Two sub-cases, matching what was reproduced against systemd 255:
#
#    5a. A plain downstream restart (the issue's literal acceptance criterion):
#        kill the stand-in "nested guest" listener and start a fresh one, then
#        reconnect through the relay. A fresh connection re-dials the current
#        downstream.
#
#    5b. A restart *storm* (the actual root cause): repeatedly kill the relay
#        listener while driving connections. The pre-#192 unit had no Restart=
#        and the default start-rate-limiter, so a storm drove the unit into
#        `failed` — the relay then accepted-but-reset every new connection until
#        a manual `systemctl restart`. The hardened unit (Restart=always +
#        StartLimitIntervalSec=0) must instead stay live and keep serving. This
#        sub-case wedges the old unit and passes the new one, so it is the real
#        regression guard.
#
# We never run `systemctl restart` on a relay unit anywhere below — recovery
# must come entirely from the unit's own restart policy.

# 5a. Plain downstream restart.
limactl shell "${INSTANCE}" -- pkill -f "http.server ${TARGET_PORT}" || true
sleep 1
limactl shell "${INSTANCE}" -- bash -c \
  "setsid nohup python3 -m http.server ${TARGET_PORT} --bind 127.0.0.1 \
     >/tmp/pf-listener2.log 2>&1 < /dev/null &" \
  || fail "could not restart the in-VM test listener"
for _ in $(seq 1 30); do
  if limactl shell "${INSTANCE}" -- \
       curl -fsS -o /dev/null "http://127.0.0.1:${VM_PORT}/"; then
    recovered=1
    break
  fi
  sleep 1
done
[ "${recovered:-0}" = 1 ] \
  || fail "relay did not recover after a plain downstream restart (issue #192)"

# 5b. Restart storm: kill the socat listener repeatedly while connecting. Eight
#     kills in ~2s comfortably exceeds systemd's default 5-starts-in-10s limit,
#     so the pre-#192 unit would latch `failed` here. The pattern matches the
#     relay's own listener (TCP4-LISTEN:<port>) so it never touches an unrelated
#     socat.
for _ in $(seq 1 8); do
  limactl shell "${INSTANCE}" -- pkill -f "socat -T .* TCP4-LISTEN:${VM_PORT}," || true
  limactl shell "${INSTANCE}" -- \
    curl -fsS -o /dev/null --max-time 2 "http://127.0.0.1:${VM_PORT}/" || true
  sleep 0.25
done
# After the storm the relay must still recover on its own.
for _ in $(seq 1 30); do
  if limactl shell "${INSTANCE}" -- \
       curl -fsS -o /dev/null "http://127.0.0.1:${VM_PORT}/"; then
    storm_ok=1
    break
  fi
  sleep 1
done
[ "${storm_ok:-0}" = 1 ] \
  || fail "relay wedged after a socat restart storm — start-rate-limiter not disabled? (issue #192 regression)"

# The relay service must still be live (not latched into `failed`), the same unit
# we never manually restarted.
limactl shell "${INSTANCE}" -- systemctl is-active --quiet "${UNIT}.service" \
  || fail "relay service ${UNIT}.service is not active after the storm"

echo "PASS: port-forward relay end-to-end (0.0.0.0 bind + socat proxy target + host auto-forward reachability + downstream-restart + storm recovery)"
