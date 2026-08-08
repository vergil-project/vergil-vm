#!/bin/bash
# vergil-provision: context=root cadence=boot
set -eux -o pipefail
# Backend-neutral inputs (#199): Lima/cloud each write this file their own way.
. /etc/vergil/provision.env

mkdir -p /etc/vergil
FORWARDS="$PORT_FORWARDS"

# Idle timeout (seconds) for each relay connection. socat -T reaps a connection
# whose data channel is silent in both directions this long, curing the
# zero-window-persist leak (#298). 120s sits well above any normal request gap
# or live-panel heartbeat and far below the old "leaks forever"; retune here.
_RELAY_IDLE_TIMEOUT=120

if [ -z "$FORWARDS" ]; then
  printf '0\n' > /etc/vergil/port-forwards.requested
  exit 0
fi

IFS=';' read -ra _fwds <<< "$FORWARDS"
printf '%s\n' "${#_fwds[@]}" > /etc/vergil/port-forwards.requested

for _f in "${_fwds[@]}"; do
  IFS='|' read -r _port _to <<< "$_f"
  if ! printf '%s' "$_port" | grep -qE '^[0-9]+$' || [ -z "$_to" ]; then
    printf 'ERROR: malformed port_forwards entry "%s" — expected "<port>|<host:port>" (declared in the repo vergil.toml [vm] port_forwards)\n' \
      "$_f" | tee /etc/vergil/provision-error >&2
    exit 1
  fi
  _unit="vergil-portforward-${_port}"
  # The heredoc body/terminator sit at the YAML block-scalar base indent (4
  # spaces) — flush-left after dedent — so the unit-file lines and the SERVICE
  # terminator land at column 0 in the executed script (cf. the
  # managed-settings.json heredoc above). A less-indented line would end the
  # YAML block; a non-column-0 terminator would never close the heredoc.
  cat > "/etc/systemd/system/${_unit}.service" <<SERVICE
[Unit]
Description=Vergil port-forward relay (:${_port} -> ${_to})
# Never let a restart storm wedge the relay (issue #192): a rapid bounce of the
# listener would trip systemd's default start-rate-limiter, latch the unit
# failed, and the relay would then accept-but-reset every new connection until a
# manual restart. Disabling the limiter keeps respawns unbounded so the relay
# always recovers on its own.
StartLimitIntervalSec=0

[Service]
# socat, not systemd-socket-proxyd (#298). proxyd has no idle/inactivity timeout
# and TCP keepalive never applies in TCP zero-window persist, so a client that
# vanishes mid-transfer strands its fds and ~600 KB of Send-Q forever; under
# sustained use the relay hits its NOFILE limit and resets every client while
# still reporting active. socat's -T reaps a connection whose data channel is
# silent for ${_RELAY_IDLE_TIMEOUT}s, freeing both fds and the Send-Q, and fork
# isolates every connection in its own child so a single wedge can never exhaust
# the whole relay. TCP4-LISTEN + bind=0.0.0.0 keeps the IPv4 0.0.0.0 listen that
# triggers Lima's auto-forward to the Mac; reuseaddr lets a respawn rebind
# immediately through TIME_WAIT.
ExecStart=/usr/bin/socat -T ${_RELAY_IDLE_TIMEOUT} TCP4-LISTEN:${_port},bind=0.0.0.0,fork,reuseaddr TCP:${_to}
# A downstream restart only kills the affected per-connection child, not the
# parent listener, so recovery is automatic; Restart= here guards the rarer case
# of the listener process itself crashing.
Restart=always
RestartSec=100ms

[Install]
WantedBy=multi-user.target
SERVICE
  # Enable (boot persistence) and start now. A port already in use makes the
  # service start fail; set -e then aborts the build loudly (issue #130) rather
  # than shipping a VM whose declared forward never bound.
  if ! systemctl enable --now "${_unit}.service"; then
    printf 'ERROR: port-forward relay for :%s failed to start (port already in use?)\n' \
      "$_port" | tee /etc/vergil/provision-error >&2
    exit 1
  fi
done
