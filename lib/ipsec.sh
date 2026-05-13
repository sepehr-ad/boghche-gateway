#!/bin/bash
set -euo pipefail

CONFIG="/etc/boghche/config.json"
IPSEC_CONF="/etc/ipsec.conf"
IPSEC_SECRETS="/etc/ipsec.secrets"

if [ ! -f "$CONFIG" ]; then
  echo "Config file not found: $CONFIG"
  exit 1
fi

MODE=$(jq -r '.mode // empty' "$CONFIG")
CONN_NAME=$(jq -r '.conn_name // "fgt"' "$CONFIG")
LEFT=$(jq -r '.left // empty' "$CONFIG")
LEFTID=$(jq -r '.leftid // .left // empty' "$CONFIG")
RIGHT=$(jq -r '.right // empty' "$CONFIG")
RIGHTID=$(jq -r '.rightid // .right // empty' "$CONFIG")
PSK=$(jq -r '.psk // empty' "$CONFIG")
IKE=$(jq -r '.ike // "aes256-sha256-modp2048!"' "$CONFIG")
ESP=$(jq -r '.esp // "aes256-sha256!"' "$CONFIG")
DPD_DELAY=$(jq -r '.dpd_delay // "10s"' "$CONFIG")
DPD_TIMEOUT=$(jq -r '.dpd_timeout // "30s"' "$CONFIG")
REKEY=$(jq -r '.rekey // false' "$CONFIG")
VTI_MARK=$(jq -r '.vti_mark // "42"' "$CONFIG")
LOCAL_SUBNET=$(jq -r '.local_subnet // empty' "$CONFIG")
REMOTE_SUBNET=$(jq -r '.remote_subnet // empty' "$CONFIG")

if [ "$REKEY" = "true" ]; then
  REKEY_VALUE="yes"
else
  REKEY_VALUE="no"
fi

if [ -z "$LEFT" ] || [ -z "$RIGHT" ] || [ -z "$LEFTID" ] || [ -z "$RIGHTID" ] || [ -z "$PSK" ]; then
  echo "Missing required IPsec values in $CONFIG"
  exit 1
fi

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
    leftsubnet=${LOCAL_SUBNET}

    right=${RIGHT}
    rightid=${RIGHTID}
    rightsubnet=${REMOTE_SUBNET}

    ike=${IKE}
    esp=${ESP}

    mark=${VTI_MARK}

    dpddelay=${DPD_DELAY}
    dpdtimeout=${DPD_TIMEOUT}
    dpdaction=restart

    rekey=${REKEY_VALUE}
    reauth=no
EOF



cat > "$IPSEC_SECRETS" <<EOF
${LEFTID} ${RIGHTID} : PSK "${PSK}"
EOF

chmod 600 "$IPSEC_SECRETS"

echo "[+] Generated ${IPSEC_CONF}"
echo "[+] Generated ${IPSEC_SECRETS}"
