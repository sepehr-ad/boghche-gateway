#!/bin/bash
set -euo pipefail

CONFIG="/etc/boghche/config.json"
METRICS="/usr/local/lib/boghche/metrics.sh"

color_connected() {
  gum style --foreground 46 --bold "$1"
}

color_warning() {
  gum style --foreground 214 --bold "$1"
}

color_error() {
  gum style --foreground 196 --bold "$1"
}

box() {
  gum style \
    --border rounded \
    --border-foreground 212 \
    --padding '0 1' \
    "$1"
}

get_peer() {
  jq -r '.right // "N/A"' "$CONFIG" 2>/dev/null || echo "N/A"
}

get_vti() {
  jq -r '.vti_if // "vti0"' "$CONFIG" 2>/dev/null || echo "vti0"
}

get_vti_ip() {
  jq -r '.vti_addr // "N/A"' "$CONFIG" 2>/dev/null || echo "N/A"
}

get_tunnel_state() {
  if ipsec statusall 2>/dev/null | grep -q ESTABLISHED; then
    color_connected "CONNECTED"
  else
    color_error "DOWN"
  fi
}

get_unbound_state() {
  state=$(systemctl is-active unbound 2>/dev/null || true)
  if [ "$state" = "active" ]; then
    color_connected "RUNNING"
  else
    color_warning "DISABLED"
  fi
}

get_xfrm_state() {
  mismatch=$(grep XfrmInTmplMismatch /proc/net/xfrm_stat 2>/dev/null | awk '{print $2}')
  mismatch=${mismatch:-0}

  if [ "$mismatch" -eq 0 ]; then
    color_connected "OK"
  else
    color_warning "WARN (${mismatch})"
  fi
}

render_top() {
  if [ -x "$METRICS" ]; then
    "$METRICS" collect >/dev/null 2>&1 || true
    "$METRICS" top 2>/dev/null || echo "No traffic data"
  else
    echo "Metrics unavailable"
  fi
}

render_dashboard() {
  clear

  HEADER=$(gum style \
    --foreground 212 \
    --border double \
    --border-foreground 212 \
    --align center \
    --width 74 \
    --padding '0 1' \
    '🌿 BOGHCHE GATEWAY')

  STATUS=$(cat <<EOF
Tunnel    : $(get_tunnel_state)
Peer      : $(get_peer)
VTI       : $(get_vti)
VTI IP    : $(get_vti_ip)
Unbound   : $(get_unbound_state)
XFRM      : $(get_xfrm_state)
EOF
)

  ACTIONS=$(cat <<EOF
[1] Configure Tunnel
[2] Start Tunnel
[3] Stop Tunnel
[4] Tunnel Health
[5] Add Route
[6] Firewall / UFW
[7] Service Status
[8] View Config
[9] Exit
EOF
)

  TALKERS=$(render_top)

  LEFT=$(printf '%s\n\n%s' "$(box "$STATUS")" "$(box "$ACTIONS")")
  RIGHT=$(box "TOP TALKERS\n\n$TALKERS")

  printf '%s\n\n' "$HEADER"
  paste <(printf '%s\n' "$LEFT") <(printf '%s\n' "$RIGHT") -d ' '

  echo
  gum style --foreground 240 'TAB navigate • ENTER select • CTRL+C quit'
}
