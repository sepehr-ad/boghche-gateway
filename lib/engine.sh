#!/bin/bash
set -euo pipefail

source /usr/local/lib/boghche/utils.sh

CONFIG="/etc/boghche/config.json"
IPSEC_GENERATOR="/usr/local/lib/boghche/ipsec.sh"
TABLE_ID=220
TABLE_NAME=vti
NAT_CHAIN="BOGHCHE-POSTROUTING"
DEFAULT_LANS=(
  "192.168.0.0/16"
  "172.16.0.0/16"
  "172.18.0.0/16"
)

if [ ! -f "$CONFIG" ]; then
  echo "Config not found: $CONFIG"
  exit 1
fi

MODE=$(jq -r '.mode // "route"' "$CONFIG")
LEFT=$(jq -r '.left // .pub_ip // empty' "$CONFIG")
RIGHT=$(jq -r '.right // .fgt_ip // empty' "$CONFIG")
WAN_IF=$(jq -r '.wan_if // "eth0"' "$CONFIG")
VTI_IF=$(jq -r '.vti_if // "vti0"' "$CONFIG")
VTI_ADDR=$(jq -r '.vti_addr // empty' "$CONFIG")
VTI_MARK=$(jq -r '.vti_mark // .mark // "42"' "$CONFIG")
MTU=$(jq -r '.mtu // "1480"' "$CONFIG")
NAT=$(jq -r '.nat // false' "$CONFIG")

if [ "$MODE" != "route" ]; then
  log "Boghche engine skipped route VTI setup mode=$MODE"
  exit 0
fi

if [ -z "$LEFT" ] || [ -z "$RIGHT" ] || [ -z "$VTI_ADDR" ]; then
  echo "Route mode requires left, right and vti_addr"
  exit 1
fi

mapfile -t CONFIG_LANS < <(
  jq -r '.lans[]? // empty' "$CONFIG")
)

LANS=( "${DEFAULT_LANS[@]}" "${CONFIG_LANS[@]}" )
LANS=( $(printf '%s
' "${LANS[@]}" | sort -u) )

echo "[vti-up] starting..."

"$IPSEC_GENERATOR"

echo "[vti-up] restarting strongSwan in its own systemd service..."
if command -v systemctl >/dev/null 2>&1; then
  systemctl restart strongswan-starter.service
else
  ipsec restart
fi
sleep 3

ip link del "$VTI_IF" 2>/dev/null || true
ip link add "$VTI_IF" type vti local "$LEFT" remote "$RIGHT" ikey "$VTI_MARK" okey "$VTI_MARK"
ip addr add "$VTI_ADDR" dev "$VTI_IF" 2>/dev/null || true
ip link set "$VTI_IF" up
ip link set "$VTI_IF" mtu "$MTU"

sysctl -w net.ipv4.ip_forward=1 >/dev/null || true
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null || true
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null || true
sysctl -w net.ipv4.conf."$WAN_IF".rp_filter=0 >/dev/null 2>&1 || true
sysctl -w net.ipv4.conf."$VTI_IF".rp_filter=0 >/dev/null || true
sysctl -w net.ipv4.conf."$VTI_IF".disable_policy=1 >/dev/null || true
sysctl -w net.ipv4.conf."$VTI_IF".disable_xfrm=0 >/dev/null 2>&1 || true

if ! grep -qE "^${TABLE_ID}[[:space:]]+${TABLE_NAME}$" /etc/iproute2/rt_tables; then
  sed -i "/[[:space:]]${TABLE_NAME}$/d" /etc/iproute2/rt_tables 2>/dev/null || true
  echo "${TABLE_ID} ${TABLE_NAME}" >> /etc/iproute2/rt_tables
fi

while ip rule del table "$TABLE_NAME" 2>/dev/null; do :; done
ip route flush table "$TABLE_NAME" 2>/dev/null || true

VTI_IP="${VTI_ADDR%%/*}"
ip rule add from "$VTI_IP/32" table "$TABLE_NAME" priority 211 2>/dev/null || true

PRIO=212
for NET in "${LANS[@]}"; do
  echo "[vti-up] Configuring LAN ${NET} on ${VTI_IF} ..."
  ip route replace "$NET" dev "$VTI_IF" 2>/dev/null || true
  ip route replace "$NET" dev "$VTI_IF" table "$TABLE_NAME" 2>/dev/null || true
  ip rule add from "$NET" table "$TABLE_NAME" priority "$PRIO" 2>/dev/null || true
  PRIO=$((PRIO + 1))
done

ip rule add iif "$WAN_IF" table "$TABLE_NAME" priority 209 2>/dev/null || true
ip route flush cache 2>/dev/null || true

iptables -t nat -N "$NAT_CHAIN" 2>/dev/null || true
iptables -t nat -F "$NAT_CHAIN" 2>/dev/null || true

if [ "$NAT" = "true" ]; then
  iptables -t nat -C POSTROUTING -j "$NAT_CHAIN" 2>/dev/null || \
    iptables -t nat -A POSTROUTING -j "$NAT_CHAIN" 2>/dev/null || true
  for NET in "${LANS[@]}"; do
    iptables -t nat -A "$NAT_CHAIN" -s "$NET" -o "$WAN_IF" -j MASQUERADE 2>/dev/null || true
  done
else
  iptables -t nat -D POSTROUTING -j "$NAT_CHAIN" 2>/dev/null || true
fi

iptables -C FORWARD -i "$VTI_IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i "$VTI_IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null || true

iptables -C FORWARD -i "$WAN_IF" -o "$VTI_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i "$WAN_IF" -o "$VTI_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

echo "[vti-up] done."
log "Boghche route engine applied mode=$MODE left=$LEFT right=$RIGHT if=$VTI_IF lans=${LANS[*]}"
exit 0
