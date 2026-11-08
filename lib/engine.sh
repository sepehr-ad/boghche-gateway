#!/bin/bash
set -euo pipefail

source /usr/local/lib/boghche/utils.sh

CONFIG="/etc/boghche/config.json"
IPSEC_GENERATOR="/usr/local/lib/boghche/ipsec.sh"
UNBOUND_GENERATOR="/usr/local/lib/boghche/unbound.sh"
TABLE_ID=200
TABLE_NAME=vti
NAT_CHAIN="BOGHCHE-POSTROUTING"
MSS_CHAIN="BOGHCHE-MSS"
FORWARD_CHAIN="BOGHCHE-FORWARD"
STRONGSWAN_ROUTE_CONF="/etc/strongswan.d/90-boghche-vti.conf"
DEFAULT_LANS=(
  "192.168.0.0/16"
  "172.16.0.0/16"
  "172.18.0.0/16"
  "10.20.30.2/32"
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
MTU=$(jq -r '.mtu // "1400"' "$CONFIG")
TCP_MSS=$(jq -r '.tcp_mss // empty' "$CONFIG")
NAT=$(jq -r '.nat // false' "$CONFIG")

if [ "$MODE" = "route" ] && { [ -z "$LEFT" ] || [ -z "$RIGHT" ] || [ -z "$VTI_ADDR" ]; }; then
  echo "Route mode requires left, right and vti_addr"
  exit 1
fi

if [ "$MODE" = "route" ]; then
  if ! [[ "$MTU" =~ ^[0-9]+$ ]] || [ "$MTU" -lt 576 ] || [ "$MTU" -gt 9000 ]; then
    echo "Invalid VTI MTU: $MTU"
    exit 1
  fi

  if [ -z "$TCP_MSS" ]; then
    TCP_MSS=$((MTU - 40))
  fi
  if ! [[ "$TCP_MSS" =~ ^[0-9]+$ ]] || [ "$TCP_MSS" -lt 536 ] || [ "$TCP_MSS" -ge "$MTU" ]; then
    echo "Invalid TCP MSS: $TCP_MSS for MTU $MTU"
    exit 1
  fi
fi

mapfile -t CONFIG_LANS < <(
  jq -r '(.lans[]? // empty), (.route_subnets[]? // empty)' "$CONFIG"
)

LANS=( "${DEFAULT_LANS[@]}" "${CONFIG_LANS[@]}" )
mapfile -t LANS < <(printf '%s\n' "${LANS[@]}" | awk 'NF' | sort -u)

VTI_IP="${VTI_ADDR%%/*}"

cleanup_strongswan_routes() {
  # Charon's default route-install rule is priority/table 220. Remove only that
  # exact conventional rule, and only when Boghche owns VTI routing.
  if [ -f "$STRONGSWAN_ROUTE_CONF" ] &&
     grep -Eq '^[[:space:]]*install_routes[[:space:]]*=[[:space:]]*no' "$STRONGSWAN_ROUTE_CONF" &&
     ip rule show | grep -Eq '^220:[[:space:]]+from all lookup 220([[:space:]]|$)'; then
    ip rule del pref 220 2>/dev/null || true
    ip route flush table 220 2>/dev/null || true
  fi
}

cleanup_stale_forecast_rules() {
  command -v iptables-legacy >/dev/null 2>&1 || return 0

  # forecast should never be loaded in Boghche VTI mode. If it is absent,
  # remove only stale ESP MARK rules that exactly match this peer/local pair
  # and Boghche's VTI mark. Never flush user mangle chains globally.
  if ! ipsec statusall 2>/dev/null | grep 'loaded plugins' | grep -qw forecast; then
    local mark_hex rule
    printf -v mark_hex '0x%x' "$VTI_MARK"

    while IFS= read -r rule; do
      [ -n "$rule" ] || continue
      iptables-legacy -t mangle $rule 2>/dev/null || true
    done < <(
      iptables-legacy -t mangle -S PREROUTING 2>/dev/null |
        awk -v right="$RIGHT" -v left="$LEFT" -v mark="$mark_hex" '
          $0 ~ "^-A PREROUTING " &&
          $0 ~ "-p esp" &&
          $0 ~ "-s " right &&
          $0 ~ "-d " left &&
          $0 ~ "-j MARK" &&
          index($0, mark) {
            sub(/^-A /, "-D ")
            print
          }'
    )
  fi
}

verify_vti_plugins() {
  local loaded
  loaded=$(ipsec statusall 2>/dev/null | grep 'loaded plugins' || true)

  if grep -qw forecast <<<"$loaded"; then
    echo "ERROR: strongSwan forecast plugin is loaded in VTI mode."
    return 1
  fi
  if grep -qw connmark <<<"$loaded"; then
    echo "ERROR: strongSwan connmark plugin is loaded in VTI mode."
    return 1
  fi
}

configure_mss() {
  iptables -t mangle -N "$MSS_CHAIN" 2>/dev/null || true
  iptables -t mangle -F "$MSS_CHAIN"
  iptables -t mangle -C FORWARD -j "$MSS_CHAIN" 2>/dev/null || \
    iptables -t mangle -I FORWARD 1 -j "$MSS_CHAIN"

  iptables -t mangle -A "$MSS_CHAIN" -i "$VTI_IF" -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --set-mss "$TCP_MSS"
  iptables -t mangle -A "$MSS_CHAIN" -o "$VTI_IF" -p tcp --tcp-flags SYN,RST SYN \
    -j TCPMSS --set-mss "$TCP_MSS"
}

configure_forwarding() {
  iptables -N "$FORWARD_CHAIN" 2>/dev/null || true
  iptables -F "$FORWARD_CHAIN"
  iptables -C FORWARD -j "$FORWARD_CHAIN" 2>/dev/null || \
    iptables -I FORWARD 1 -j "$FORWARD_CHAIN"

  iptables -A "$FORWARD_CHAIN" -i "$VTI_IF" -o "$WAN_IF" -j ACCEPT
  iptables -A "$FORWARD_CHAIN" -i "$WAN_IF" -o "$VTI_IF" \
    -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT

  # Remove exact legacy rules for the current interface pair from older releases.
  while iptables -C FORWARD -i "$VTI_IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD -i "$VTI_IF" -o "$WAN_IF" -j ACCEPT 2>/dev/null || break
  done
  while iptables -C FORWARD -i "$WAN_IF" -o "$VTI_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null; do
    iptables -D FORWARD -i "$WAN_IF" -o "$VTI_IF" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || break
  done
}

echo "[vti-up] starting..."

"$IPSEC_GENERATOR"

if command -v systemctl >/dev/null 2>&1; then
  systemctl restart strongswan-starter.service
else
  ipsec restart
fi
sleep 3

if [ "$MODE" != "route" ]; then
  if [ -x "$UNBOUND_GENERATOR" ]; then
    "$UNBOUND_GENERATOR" || true
  fi
  log "Boghche policy-mode IPsec configuration applied"
  exit 0
fi

verify_vti_plugins
cleanup_stale_forecast_rules
cleanup_strongswan_routes

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

sed -i "/^[0-9][0-9]*[[:space:]]\+${TABLE_NAME}$/d" /etc/iproute2/rt_tables 2>/dev/null || true
echo "${TABLE_ID} ${TABLE_NAME}" >> /etc/iproute2/rt_tables

while read -r line; do
  PRIO=$(echo "$line" | awk '{print $1}' | tr -d ':')
  [ -n "$PRIO" ] && ip rule del priority "$PRIO" 2>/dev/null || true
done < <(ip rule | grep "lookup ${TABLE_NAME}" || true)

ip route flush table "$TABLE_NAME" 2>/dev/null || true

ip rule add from "$VTI_IP/32" table "$TABLE_NAME" 2>/dev/null || true

for NET in "${LANS[@]}"; do
  echo "[vti-up] Configuring LAN ${NET} on ${VTI_IF} ..."

  ip route replace "$NET" dev "$VTI_IF" 2>/dev/null || true
  ip route replace "$NET" dev "$VTI_IF" table "$TABLE_NAME" 2>/dev/null || true

  ip rule add from "$NET" table "$TABLE_NAME" 2>/dev/null || true
done

ip rule add iif "$WAN_IF" table "$TABLE_NAME" 2>/dev/null || true

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

configure_mss
configure_forwarding

if [ -x "$UNBOUND_GENERATOR" ]; then
  "$UNBOUND_GENERATOR" || true
fi

echo "[vti-up] done."
log "Boghche VTI engine applied left=$LEFT right=$RIGHT if=$VTI_IF mtu=$MTU mss=$TCP_MSS table=${TABLE_ID}/${TABLE_NAME}"
exit 0
