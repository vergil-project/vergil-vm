set -eu
mkdir -p /etc/systemd/logind.conf.d
printf '[Login]\nNAutoVTs=0\nReserveVT=0\n' \
  > /etc/systemd/logind.conf.d/10-vergil-novt.conf
if systemctl is-active --quiet systemd-logind 2>/dev/null; then
  systemctl try-restart systemd-logind || true
fi
