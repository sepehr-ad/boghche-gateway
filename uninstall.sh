#!/bin/bash
set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "Please run as root: sudo bash uninstall.sh"
  exit 1
fi

echo "[+] Stopping Boghche services..."
systemctl stop boghche.service 2>/dev/null || true
systemctl disable boghche.service 2>/dev/null || true

if [ -f /etc/boghche/config.json ]; then
  VTI_IF=$(jq -r '.vti_if // "vti0"' /etc/boghche/config.json 2>/dev/null || echo vti0)
else
  VTI_IF="vti0"
fi

ip link del "$VTI_IF" 2>/dev/null || true

echo "[+] Removing Boghche-managed firewall chains..."
iptables -t nat -D POSTROUTING -j BOGHCHE-POSTROUTING 2>/dev/null || true
iptables -t nat -F BOGHCHE-POSTROUTING 2>/dev/null || true
iptables -t nat -X BOGHCHE-POSTROUTING 2>/dev/null || true

iptables -t mangle -D FORWARD -j BOGHCHE-MSS 2>/dev/null || true
iptables -t mangle -F BOGHCHE-MSS 2>/dev/null || true
iptables -t mangle -X BOGHCHE-MSS 2>/dev/null || true

iptables -D FORWARD -j BOGHCHE-FORWARD 2>/dev/null || true
iptables -F BOGHCHE-FORWARD 2>/dev/null || true
iptables -X BOGHCHE-FORWARD 2>/dev/null || true

echo "[+] Restoring StrongSwan plugin configuration when backups exist..."
BACKUP_DIR="/var/lib/boghche/strongswan-config-backup"
if [ -f "$BACKUP_DIR/connmark.conf.original" ]; then
  cp -a "$BACKUP_DIR/connmark.conf.original" /etc/strongswan.d/charon/connmark.conf
elif grep -q 'Managed by Boghche Gateway' /etc/strongswan.d/charon/connmark.conf 2>/dev/null; then
  rm -f /etc/strongswan.d/charon/connmark.conf
fi

if [ -f "$BACKUP_DIR/forecast.conf.original" ]; then
  cp -a "$BACKUP_DIR/forecast.conf.original" /etc/strongswan.d/charon/forecast.conf
elif grep -q 'Managed by Boghche Gateway' /etc/strongswan.d/charon/forecast.conf 2>/dev/null; then
  rm -f /etc/strongswan.d/charon/forecast.conf
fi

rm -f /etc/strongswan.d/90-boghche-vti.conf
rm -f /etc/systemd/system/boghche.service
rm -f /usr/local/bin/boghche
rm -rf /usr/local/lib/boghche
rm -rf /etc/boghche
rm -f /etc/sysctl.d/99-boghche.conf

systemctl daemon-reload
systemctl restart strongswan-starter.service 2>/dev/null || true

echo "[✓] Boghche Gateway removed."
echo "Backups and telemetry under /var/backups/boghche and /var/lib/boghche were preserved."
