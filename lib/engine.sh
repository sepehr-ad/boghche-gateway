#!/bin/bash
set -euo pipefail

source /usr/local/lib/boghche/utils.sh

CONFIG="/etc/boghche/config.json"

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
VTI_MARK=$(jq -r '.vti_mark // "42"' "$CONFIG")
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

mapfile -t LANS < <(
  jq -r '
    [
      (.lans[]? // empty),
      (.route_subnets[]? // empty),
      (.routes[]? // empty),
      (.route_subnet // empty),
      (.nat_sources[]? // empty),
      (.nat_source // empty)
    ]
    | map(select(. != null and . != "" and . != "null" and . != "0.0.0.0/0"))
    | unique[]
  ' "$CONFIG"
)

if [ "${#LANS[@]}" -eq 0 ]; then
  echo "Route mode requires at least one LAN/source subnet"
  echo "Use route_subnet, route_subnets, lans, nat_source, or nat_sources in $CONFIG"
  exit 1
fi

echo "[vti-up] starting..."

echo "[vti-up] restarting strongSwan in its own systemd service..."
if command -v systemctl >/dev/null 2>&1; then
  systemctl restart strongswan-starter.service
else
  ipsec restart
fi
sleep 3

ip link del "$VTI_IF" 2>/dev/null || true
ip link add "$VTI_IF" type vti local "$LEFT" remote "$RIGHT" key "$VTI_MARK"
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

grep -qE '^200[[:space:]]+vti' /etc/iproute2/rt_tables || echo "200 vti" >> /etc/iproute2/rt_tables

# Remove stale Boghche VTI rules. Ignore failures so repeated restarts are safe.
ip rule | awk '/lookup vti/ {gsub(":", "", $1); print $1}' | while read -r PRIO; do
  [ -n "$PRIO" ] && ip rule del priority "$PRIO" 2>/dev/null || true
done

ip route flush table vti 2>/dev/null || true

VTI_IP="${VTI_ADDR%%/*}"

# Add VTI source rule once. The exact priority is not critical, but stable priorities help debugging.
ip rule add from "$VTI_IP/32" table vti priority 211 2>/dev/null || true

PRIO=212
for NET in "${LANS[@]}"; do
  echo "[vti-up] Configuring LAN ${NET} on ${VTI_IF} ..."

  ip route replace "$NET" dev "$VTI_IF" 2>/dev/null || true
  ip route replace "$NET" dev "$VTI_IF" table vti 2>/dev/null || true

  ip rule del from "$NET" table vti 2>/dev/null || true
  ip rule add from "$NET" table vti priority "$PRIO" 2>/dev/null || true
  PRIO=$((PRIO + 1))
done

ip rule del iif "$WAN_IF" table vti 2>/dev/null || true
ip rule add iif "$WAN_IF" table vti priority 209 2>/dev/null || true
ip route flush cache 2>/dev/null || true

if [ "$NAT" = "true" ]; then
  iptables -t nat -F POSTROUTING 2>/dev/null || true
  for NET in "${LANS[@]}"; do
    iptables -t nat -A POSTROUTING -s "$NET" -o "$WAN_IF" -j MASQUERADE 2>/dev/null || true
  done
fi

iptables -C FORWARD -i "$VTI_IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i "$VTI_IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null || true

iptables -C FORWARD -i "$WAN_IF" -o "$VTI_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
  iptables -A FORWARD -i "$WAN_IF" -o "$VTI_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || true

echo "[vti-up] done."
log "Boghche route engine applied mode=$MODE left=$LEFT right=$RIGHT if=$VTI_IF"
exit 0
