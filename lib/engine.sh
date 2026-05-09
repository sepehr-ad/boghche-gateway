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

  if [ "$NAT" = "true" ] && [ -n "$NAT_SOURCE" ] && [ "$NAT_SOURCE" != "null" ]; then
    iptables -t nat -C POSTROUTING -s "$NAT_SOURCE" -o "$VTI_IF" -j MASQUERADE 2>/dev/null || \
      iptables -t nat -A POSTROUTING -s "$NAT_SOURCE" -o "$VTI_IF" -j MASQUERADE
  fi
fi

log "Boghche engine applied mode=$MODE left=$LEFT right=$RIGHT"
exit 0
