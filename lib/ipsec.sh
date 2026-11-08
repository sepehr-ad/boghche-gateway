#!/bin/bash
set -euo pipefail

CONFIG="/etc/boghche/config.json"
IPSEC_CONF="/etc/ipsec.conf"
IPSEC_SECRETS="/etc/ipsec.secrets"
STRONGSWAN_ROUTE_CONF="/etc/strongswan.d/90-boghche-vti.conf"
STRONGSWAN_PLUGIN_DIR="/etc/strongswan.d/charon"
STRONGSWAN_CONNMARK_CONF="${STRONGSWAN_PLUGIN_DIR}/connmark.conf"
STRONGSWAN_FORECAST_CONF="${STRONGSWAN_PLUGIN_DIR}/forecast.conf"
STRONGSWAN_BACKUP_DIR="/var/lib/boghche/strongswan-config-backup"

if [ ! -f "$CONFIG" ]; then
  echo "Config file not found: $CONFIG"
  exit 1
fi

MODE=$(jq -r '.mode // "route"' "$CONFIG")
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
DPD_ACTION=$(jq -r '.dpd_action // "restart"' "$CONFIG")
CLOSE_ACTION=$(jq -r '.close_action // "restart"' "$CONFIG")
KEYINGTRIES=$(jq -r '.keyingtries // "%forever"' "$CONFIG")
REKEY=$(jq -r '.rekey // false' "$CONFIG")
IKE_LIFETIME=$(jq -r '.ikelifetime // "8h"' "$CONFIG")
LIFETIME=$(jq -r '.lifetime // "1h"' "$CONFIG")
MARGINTIME=$(jq -r '.margintime // "9m"' "$CONFIG")
VTI_MARK=$(jq -r '.vti_mark // .mark // "42"' "$CONFIG")
LOCAL_SUBNET=$(jq -r '.local_subnet // empty' "$CONFIG")
REMOTE_SUBNET=$(jq -r '.remote_subnet // empty' "$CONFIG")

backup_strongswan_plugin_config() {
  local source_file="$1"
  local backup_file="$2"

  if [ -f "$source_file" ] && [ ! -e "$backup_file" ]; then
    cp -a "$source_file" "$backup_file"
  fi
}

restore_strongswan_plugin_config() {
  local managed_file="$1"
  local backup_file="$2"

  if grep -q 'Managed by Boghche Gateway' "$managed_file" 2>/dev/null; then
    if [ -f "$backup_file" ]; then
      cp -a "$backup_file" "$managed_file"
    else
      rm -f "$managed_file"
    fi
  fi
}

configure_strongswan_mode() {
  mkdir -p "$STRONGSWAN_PLUGIN_DIR" "$STRONGSWAN_BACKUP_DIR"

  if [ "$MODE" = "route" ]; then
    backup_strongswan_plugin_config "$STRONGSWAN_CONNMARK_CONF" \
      "$STRONGSWAN_BACKUP_DIR/connmark.conf.original"
    backup_strongswan_plugin_config "$STRONGSWAN_FORECAST_CONF" \
      "$STRONGSWAN_BACKUP_DIR/forecast.conf.original"

    cat > "$STRONGSWAN_ROUTE_CONF" <<'EOF'
# Managed by Boghche Gateway for route-based/VTI mode.
# Boghche manages VTI routes explicitly; charon table 220 is not used.
charon {
    install_routes = no
}
EOF

    # These exact plugin files are intentionally managed instead of relying on
    # an override file whose include order could vary between distributions.
    cat > "$STRONGSWAN_CONNMARK_CONF" <<'EOF'
# Managed by Boghche Gateway for route-based/VTI mode.
# strongSwan recommends disabling connmark when a VTI interface is used.
connmark {
    load = no
}
EOF

    cat > "$STRONGSWAN_FORECAST_CONF" <<'EOF'
# Managed by Boghche Gateway for route-based/VTI mode.
# forecast installs Netfilter MARK rules for marked SAs and conflicts with
# Boghche's VTI/XFRM mark ownership.
forecast {
    load = no
}
EOF
  else
    rm -f "$STRONGSWAN_ROUTE_CONF"
    restore_strongswan_plugin_config "$STRONGSWAN_CONNMARK_CONF" \
      "$STRONGSWAN_BACKUP_DIR/connmark.conf.original"
    restore_strongswan_plugin_config "$STRONGSWAN_FORECAST_CONF" \
      "$STRONGSWAN_BACKUP_DIR/forecast.conf.original"
  fi
}

if [ "$REKEY" = "true" ]; then
  REKEY_VALUE="yes"
else
  REKEY_VALUE="no"
fi

if [ -z "$LEFT" ] || [ -z "$RIGHT" ] || [ -z "$LEFTID" ] || [ -z "$RIGHTID" ] || [ -z "$PSK" ]; then
  echo "Missing required IPsec values in $CONFIG"
  exit 1
fi

if [ "$MODE" = "policy" ]; then
  [ -n "$LOCAL_SUBNET" ] || { echo "Policy mode requires local_subnet"; exit 1; }
  [ -n "$REMOTE_SUBNET" ] || { echo "Policy mode requires remote_subnet"; exit 1; }
  LEFT_SUBNET="$LOCAL_SUBNET"
  RIGHT_SUBNET="$REMOTE_SUBNET"
else
  LEFT_SUBNET="0.0.0.0/0"
  RIGHT_SUBNET="0.0.0.0/0"
fi

configure_strongswan_mode

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
    leftsubnet=${LEFT_SUBNET}

    right=${RIGHT}
    rightid=${RIGHTID}
    rightsubnet=${RIGHT_SUBNET}

    ike=${IKE}
    esp=${ESP}

    mark=${VTI_MARK}

    dpddelay=${DPD_DELAY}
    dpdtimeout=${DPD_TIMEOUT}
    dpdaction=${DPD_ACTION}
    closeaction=${CLOSE_ACTION}
    keyingtries=${KEYINGTRIES}

    ikelifetime=${IKE_LIFETIME}
    lifetime=${LIFETIME}
    margintime=${MARGINTIME}

    rekey=${REKEY_VALUE}
    reauth=no
    mobike=no
    installpolicy=yes
EOF

cat > "$IPSEC_SECRETS" <<EOF
${LEFTID} ${RIGHTID} : PSK "${PSK}"
EOF

chmod 600 "$IPSEC_SECRETS"

echo "[+] Generated ${IPSEC_CONF}"
echo "[+] Generated ${IPSEC_SECRETS}"
