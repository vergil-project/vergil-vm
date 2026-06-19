#!/bin/bash
set -eux -o pipefail
# Backend-neutral inputs (#199): Lima/cloud each write this file their own way.
. /etc/vergil/provision.env

mkdir -p /etc/vergil
FORWARDS="$PORT_FORWARDS"

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
  # Heredoc bodies/terminators sit at the YAML block-scalar base indent (4
  # spaces) — flush-left after dedent — so the unit-file lines and the
  # terminators land at column 0 in the executed script (cf. the
  # managed-settings.json heredoc above). A less-indented line would end the
  # YAML block; a non-column-0 terminator would never close the heredoc.
  cat > "/etc/systemd/system/${_unit}.socket" <<SOCKET
[Unit]
Description=Vergil port-forward relay socket (:${_port} -> ${_to})

[Socket]
ListenStream=0.0.0.0:${_port}

[Install]
WantedBy=sockets.target
SOCKET
  cat > "/etc/systemd/system/${_unit}.service" <<SERVICE
[Unit]
Description=Vergil port-forward relay (:${_port} -> ${_to})
Requires=${_unit}.socket
After=${_unit}.socket
# Never let a restart storm wedge the relay (issue #192). When the
# downstream restarts it can RST the proxyd's held connections and the
# proxyd exits; Restart= below then respawns it. Under a rapid bounce
# those respawns would trip systemd's default start-rate-limiter, fail
# the unit AND cascade-fail the .socket, and the relay then accepts but
# resets every new connection until a manual restart — the exact symptom
# reported. Disabling the limiter keeps respawns unbounded so the relay
# always recovers on its own.
StartLimitIntervalSec=0

[Service]
ExecStart=/usr/lib/systemd/systemd-socket-proxyd ${_to}
# systemd-socket-proxyd is a single long-lived process that inherits the
# listening socket (its only supported mode — Accept=no; it cannot proxy
# a per-connection accepted socket, so the Accept=yes idiom resets every
# connection). Respawn it whenever it exits so a downstream restart that
# kills it is recovered transparently; the replacement re-inherits the
# socket and re-dials the current downstream per new connection.
Restart=always
RestartSec=100ms
SERVICE
  # Enable (boot persistence) and start now. A port already in use makes
  # the socket start fail; set -e then aborts the build loudly (issue #130)
  # rather than shipping a VM whose declared forward never bound.
  if ! systemctl enable --now "${_unit}.socket"; then
    printf 'ERROR: port-forward relay for :%s failed to start (port already in use?)\n' \
      "$_port" | tee /etc/vergil/provision-error >&2
    exit 1
  fi
done
