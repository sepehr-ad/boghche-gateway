#!/bin/bash
set -euo pipefail

CONFIG="/etc/boghche/config.json"
UNBOUND_DIR="/etc/unbound/unbound.conf.d"
UNBOUND_CONF="${UNBOUND_DIR}/boghche.conf"

if [ ! -f "$CONFIG" ]; then
  echo "Config file not found: $CONFIG"
  exit 1
fi

ENABLED=$(jq -r '.unbound // false' "$CONFIG")

if [ "$ENABLED" != "true" ]; then
  echo "[unbound] skipped"
  exit 0
fi

LISTEN_IP=$(jq -r '.unbound_listen_ip // .vti_addr // empty' "$CONFIG" | cut -d/ -f1)
PRIMARY_DNS=$(jq -r '.dns_upstreams[0] // "8.8.8.8@853#dns.google"' "$CONFIG")
SECONDARY_DNS=$(jq -r '.dns_upstreams[1] // "8.8.4.4@853#dns.google"' "$CONFIG")

mkdir -p "$UNBOUND_DIR"

apt-get update -y >/dev/null 2>&1 || true
apt-get install -y unbound ca-certificates >/dev/null 2>&1 || true

cat > "$UNBOUND_CONF" <<EOF
server:
    verbosity: 1

    interface: 127.0.0.1
    interface: ${LISTEN_IP}
    port: 53

    do-ip4: yes
    do-ip6: no

    access-control: 127.0.0.0/8 allow
    access-control: 10.11.11.0/30 allow
    access-control: 10.20.30.0/30 allow
    access-control: 192.168.0.0/16 allow
    access-control: 172.16.0.0/16 allow
    access-control: 172.18.0.0/16 allow

    access-control: 0.0.0.0/0 refuse

    hide-identity: yes
    hide-version: yes
    qname-minimisation: yes

    tls-cert-bundle: /etc/ssl/certs/ca-certificates.crt

    cache-min-ttl: 60
    cache-max-ttl: 86400

forward-zone:
    name: "."
    forward-tls-upstream: yes

    forward-addr: ${PRIMARY_DNS}
    forward-addr: ${SECONDARY_DNS}
EOF

unbound-checkconf
systemctl enable unbound >/dev/null 2>&1 || true
systemctl restart unbound

echo "[unbound] generated ${UNBOUND_CONF}"
