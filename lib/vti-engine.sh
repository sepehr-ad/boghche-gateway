#!/bin/bash

CONFIG="/etc/baghcheh/config.json"
VTI_IF="vti0"

if [ ! -f "$CONFIG" ]; then
  echo "Config file not found! Run: sudo baghcheh init"
  exit 1
fi

PUB_IP=$(jq -r .pub_ip $CONFIG)
FGT_IP=$(jq -r .fgt_ip $CONFIG)
WAN_IF=$(jq -r .wan_if $CONFIG)
VTI_ADDR=$(jq -r .vti_addr $CONFIG)

echo "[+] Creating VTI Interface..."

ip link del ${VTI_IF} 2>/dev/null || true
ip link add ${VTI_IF} type vti local ${PUB_IP} remote ${FGT_IP} key 42
ip addr add ${VTI_ADDR} dev ${VTI_IF}
ip link set ${VTI_IF} up

sysctl -w net.ipv4.ip_forward=1
sysctl -w net.ipv4.conf.${VTI_IF}.rp_filter=0
sysctl -w net.ipv4.conf.${VTI_IF}.disable_policy=1

echo "[+] Applying NAT..."
iptables -t nat -A POSTROUTING -o ${WAN_IF} -j MASQUERADE

echo "[✓] Baghcheh Gateway is Ready."
