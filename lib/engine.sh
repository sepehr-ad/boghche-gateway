#!/bin/bash
source /usr/local/lib/boghche/utils.sh

CONFIG="/etc/boghche/config.json"
VTI_IF="vti0"

if [ ! -f "$CONFIG" ]; then
  echo "Config not found."
  exit 1
fi

PUB_IP=$(jq -r .pub_ip $CONFIG)
FGT_IP=$(jq -r .fgt_ip $CONFIG)
WAN_IF=$(jq -r .wan_if $CONFIG)
VTI_ADDR=$(jq -r .vti_addr $CONFIG)
MTU=$(jq -r .mtu $CONFIG)
NAT=$(jq -r .nat $CONFIG)

ip link del ${VTI_IF} 2>/dev/null || true
ip link add ${VTI_IF} type vti local ${PUB_IP} remote ${FGT_IP} key 42
ip addr add ${VTI_ADDR} dev ${VTI_IF}
ip link set ${VTI_IF} up

[ "$MTU" != "null" ] && ip link set ${VTI_IF} mtu ${MTU}

sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.${VTI_IF}.rp_filter=0
sysctl -w net.ipv4.conf.${VTI_IF}.disable_policy=1

if [ "$NAT" == "true" ]; then
  iptables -t nat -A POSTROUTING -o ${WAN_IF} -j MASQUERADE
fi

log "Tunnel started between $PUB_IP and $FGT_IP"
