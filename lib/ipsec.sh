#!/bin/bash
set -euo pipefail

CONFIG="/etc/boghche/config.json"
IPSEC_CONF="/etc/ipsec.conf"
IPSEC_SECRETS="/etc/ipsec.secrets"

if [ ! -f "$CONFIG" ]; then
  echo "Config file not found: $CONFIG"
  exit 1
fi

MODE=$(jq -r .mode "$CONFIG")
CONN_NAME=$(jq -r .conn_name "$CONFIG")
LEFT=$(jq -r .left "$CONFIG")
LEFTID=$(jq -r .leftid "$CONFIG")
RIGHT=$(jq -r .right "$CONFIG")
RIGHTID=$(jq -r .rightid "$CONFIG")
PSK=$(jq -r .psk "$CONFIG")
IKE=$(jq -r .ike "$CONFIG")
ESP=$(jq -r .esp "$CONFIG")
DPD_DELAY=$(jq -r .dpd_delay "$CONFIG")
DPD_TIMEOUT=$(jq -r .dpd_timeout "$CONFIG")
REKEY=$(jq -r .rekey "$CONFIG")
VTI_MARK=$(jq -r .vti_mark "$CONFIG")
LOCAL_SUBNET=$(jq -r .local_subnet "$CONFIG")
REMOTE_SUBNET=$(jq -r .remote_subnet "$CONFIG")

cat > "$IPSEC_CONF" <<EOF
config setup
    charondebug="ike 2, knl 2, cfg 2"
    uniqueids=yes

conn ${CONN_NAME}
    auto=start
    type=tunnel
    keyexchange=ikev2
    authby=secret

    left=${LEFT}
    leftid=${LEFTID}

    right=${RIGHT}
    rightid=${RIGHTID}

    ike=${IKE}
    esp=${ESP}

    dpddelay=${DPD_DELAY}
    dpdtimeout=${DPD_TIMEOUT}
    dpdaction=restart

    rekey=${REKEY}
EOF

if [ "$MODE" = "route" ]; then
cat >> "$IPSEC_CONF" <<EOF

    leftsubnet=0.0.0.0/0
    rightsubnet=0.0.0.0/0

    mark=${VTI_MARK}

    installpolicy=no
    install_routes=no
EOF
else
cat >> "$IPSEC_CONF" <<EOF

    leftsubnet=${LOCAL_SUBNET}
    rightsubnet=${REMOTE_SUBNET}
EOF
fi

cat > "$IPSEC_SECRETS" <<EOF
${LEFTID} ${RIGHTID} : PSK "${PSK}"
EOF

chmod 600 "$IPSEC_SECRETS"

echo "[+] Generated ${IPSEC_CONF}"
echo "[+] Generated ${IPSEC_SECRETS}"
