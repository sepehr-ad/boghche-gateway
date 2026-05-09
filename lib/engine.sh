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
MTU=$(jq -r '.mtu // ""' "$CONFIG")
ROUTE_SUBNET=$(jq -r '.route_subnet // empty' "$CONFIG")
NAT=$(jq -r '.nat // false' "$CONFIG")
NAT_SOURCE=$(jq -r '.nat_source // empty' "$CONFIG")

sysctl -w net.ipv4.ip_forward=1 >/dev/null
sysctl -w net.ipv4.conf.all.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.default.rp_filter=0 >/dev/null
sysctl -w net.ipv4.conf.${WAN_IF}.rp_filter=0 >/dev/null 2>&1 || true

if ! grep -qE '^200[[:space:]]+vti' /etc/iproute2/rt_tables; then
  echo '200 vti' >> /etc/iproute2/rt_tables
fi

if [ "$MODE" = "route" ]; then
  if [ -z "$LEFT" ] || [ -z "$RIGHT" ] || [ -z "$VTI_ADDR" ]; then
    echo "Route mode requires left, right and vti_addr"
    exit 1
  fi

  ip link del "$VTI_IF" 2>/dev/null || true
  ip link add "$VTI_IF" type vti local "$LEFT" remote "$RIGHT" key "$VTI_MARK"
  ip addr add "$VTI_ADDR" dev "$VTI_IF" 2>/dev/null || true
  ip link set "$VTI_IF" up

  if [ -n "$MTU" ] && [ "$MTU" != "null" ]; then
    ip link set "$VTI_IF" mtu "$MTU"
  fi

  sysctl -w net.ipv4.conf."$VTI_IF".rp_filter=0 >/dev/null
  sysctl -w net.ipv4.conf."$VTI_IF".disable_policy=1 >/dev/null

  if [ -n "$ROUTE_SUBNET" ] && [ "$ROUTE_SUBNET" != "null" ] && [ "$ROUTE_SUBNET" != "0.0.0.0/0" ]; then
    ip route replace "$ROUTE_SUBNET" dev "$VTI_IF"
  fi

  ip route replace default dev "$VTI_IF" table vti

  while ip rule del from "$ROUTE_SUBNET" table vti 2>/dev/null; do true; done
  while ip rule del from "${VTI_ADDR%%/*}" table vti 2>/dev/null; do true; done
  while ip rule del iif "$WAN_IF" table vti 2>/dev/null; do true; done

  if [ -n "$ROUTE_SUBNET" ] && [ "$ROUTE_SUBNET" != "null" ] && [ "$ROUTE_SUBNET" != "0.0.0.0/0" ]; then
    ip rule add from "$ROUTE_SUBNET" table vti 2>/dev/null || true
  fi
  ip rule add from "${VTI_ADDR%%/*}" table vti 2>/dev/null || true

  ip route flush cache

  if [ "$NAT" = "true" ] && [ -n "$NAT_SOURCE" ] && [ "$NAT_SOURCE" != "null" ]; then
    iptables -t nat -C POSTROUTING -s "$NAT_SOURCE" -o "$WAN_IF" -j MASQUERADE 2>/dev/null || \
      iptables -t nat -A POSTROUTING -s "$NAT_SOURCE" -o "$WAN_IF" -j MASQUERADE

    iptables -C FORWARD -i "$VTI_IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null || \
      iptables -A FORWARD -i "$VTI_IF" -o "$WAN_IF" -j ACCEPT

    iptables -C FORWARD -i "$WAN_IF" -o "$VTI_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || \
      iptables -A FORWARD -i "$WAN_IF" -o "$VTI_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT
  fi
fi

log "Boghche engine applied mode=$MODE left=$LEFT right=$RIGHT"
exit 0
