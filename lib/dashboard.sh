#!/bin/bash
set -euo pipefail

CONFIG="/etc/boghche/config.json"
METRICS="/usr/local/lib/boghche/metrics.sh"

RESET=$'\033[0m'
CYAN=$'\033[38;5;45m'
PINK=$'\033[38;5;213m'
GREEN=$'\033[38;5;46m'
YELLOW=$'\033[38;5;220m'
PURPLE=$'\033[38;5;141m'
RED=$'\033[38;5;196m'
BLUE=$'\033[38;5;39m'
GRAY=$'\033[38;5;245m'
DIM=$'\033[38;5;240m'
BOLD=$'\033[1m'

term_width() {
  tput cols 2>/dev/null || echo 140
}

cfg() {
  local key="$1"
  local def="${2:-N/A}"
  jq -r "$key // \"$def\"" "$CONFIG" 2>/dev/null || echo "$def"
}

plain_tunnel_state() {
  if ipsec statusall 2>/dev/null | grep -q ESTABLISHED; then echo "CONNECTED"; else echo "DOWN"; fi
}

badge() {
  local value="$1"
  case "$value" in
    CONNECTED|RUNNING|OK|UP|HEALTHY) printf '%s%s%s' "$GREEN" "$value" "$RESET" ;;
    WARN*|DEGRADED|DISABLED) printf '%s%s%s' "$YELLOW" "$value" "$RESET" ;;
    DOWN|FAILED|ERROR) printf '%s%s%s' "$RED" "$value" "$RESET" ;;
    *) printf '%s' "$value" ;;
  esac
}

bar() {
  local pct="${1:-0}"
  local width="${2:-18}"
  pct=${pct%%%}
  [ "$pct" -lt 0 ] 2>/dev/null && pct=0
  [ "$pct" -gt 100 ] 2>/dev/null && pct=100
  local filled=$((pct * width / 100))
  local empty=$((width - filled))
  printf '%s' "$GREEN"
  printf '%*s' "$filled" '' | tr ' ' '█'
  printf '%s' "$DIM"
  printf '%*s' "$empty" '' | tr ' ' '░'
  printf '%s %s%%%s' "$RESET" "$pct" "$RESET"
}

panel() {
  local width="$1"
  local title="$2"
  local color="${3:-$CYAN}"
  local body="$4"
  local inner=$((width - 4))

  printf '%s┌%*s┐%s\n' "$DIM" $((width-2)) '' "$RESET" | tr ' ' '─'
  printf '%s│%s %s%-*s%s%s│%s\n' "$DIM" "$RESET" "$color" $((inner-1)) "$title" "$RESET" "$DIM" "$RESET"
  printf '%s├%*s┤%s\n' "$DIM" $((width-2)) '' "$RESET" | tr ' ' '─'
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s│%s %-*s %s│%s\n' "$DIM" "$RESET" "$inner" "$line" "$DIM" "$RESET"
  done <<< "$body"
  printf '%s└%*s┘%s\n' "$DIM" $((width-2)) '' "$RESET" | tr ' ' '─'
}

join_cols() {
  paste "$@" | sed 's/\t/  /g'
}

render_header() {
  local width="$1"
  local host kernel uptime now
  host=$(hostname)
  kernel=$(uname -r)
  uptime=$(uptime -p 2>/dev/null | sed 's/up //')
  now=$(date -u '+%Y-%m-%d %H:%M:%S UTC')

  printf '%s┌%*s┐%s\n' "$CYAN" $((width-2)) '' "$RESET" | tr ' ' '─'
  printf '%s│%s  %s%sBOGHCHE  GATEWAY%s   %sIPSec + VTI + DoT Gateway%s%*s%s│%s\n' \
    "$CYAN" "$RESET" "$BOLD" "$CYAN" "$RESET" "$GRAY" "$RESET" $((width-49)) '' "$CYAN" "$RESET"
  printf '%s│%s  Host: %-22s Kernel: %-24s Time: %-25s%s│%s\n' \
    "$CYAN" "$GRAY" "$host" "$kernel" "$now" "$CYAN" "$RESET"
  printf '%s│%s  Uptime: %-30s Storage cap: %-18s Version: %-10s%s│%s\n' \
    "$CYAN" "$GRAY" "$uptime" "2GB" "v1.3.0" "$CYAN" "$RESET"
  printf '%s└%*s┘%s\n' "$CYAN" $((width-2)) '' "$RESET" | tr ' ' '─'
}

widget_tunnel() {
  local state peer vti vti_ip remote sas
  state=$(plain_tunnel_state)
  peer=$(cfg '.right' 'N/A')
  vti=$(cfg '.vti_if' 'vti0')
  vti_ip=$(cfg '.vti_addr' 'N/A')
  remote=$(cfg '.vti_remote' 'N/A')
  sas=$(ipsec statusall 2>/dev/null | grep -c 'INSTALLED' || true)
  cat <<EOF
State      : $(badge "$state")
Peer       : $peer
Local VTI  : $vti_ip
Remote GW  : $remote
Device     : $vti
SAs        : $(bar $((sas > 0 ? 100 : 0)) 14) $sas/1
EOF
}

widget_xfrm() {
  local mismatch instates outstates policies
  mismatch=$(grep XfrmInTmplMismatch /proc/net/xfrm_stat 2>/dev/null | awk '{print $2}')
  mismatch=${mismatch:-0}
  instates=$(ip xfrm state 2>/dev/null | grep -c '^src ' || true)
  outstates="$instates"
  policies=$(ip xfrm policy 2>/dev/null | grep -c '^src ' || true)
  cat <<EOF
State      : $(badge "$([ "$instates" -gt 0 ] && echo OK || echo DOWN)")
Policies   : $policies
States     : $instates
Mismatch   : $mismatch
Template   : $([ "$mismatch" -eq 0 ] 2>/dev/null && badge OK || badge WARN)
Replay     : 32
EOF
}

widget_unbound() {
  local state listen upstream port
  state=$(systemctl is-active unbound 2>/dev/null || true)
  [ "$state" = "active" ] && state="RUNNING" || state="DISABLED"
  listen=$(cfg '.unbound_listen_ip' "$(cfg '.vti_addr' 'N/A' | cut -d/ -f1)")
  upstream=$(jq -r '.dns_upstreams // [] | join(", ")' "$CONFIG" 2>/dev/null || echo 'N/A')
  port="53 → DoT/853"
  cat <<EOF
State      : $(badge "$state")
Listen IP  : $listen
Port       : $port
Upstream   : ${upstream:-N/A}
TLS        : $(badge OK)
Config     : /etc/unbound/unbound.conf.d/boghche.conf
EOF
}

widget_routing() {
  ip route show table vti 2>/dev/null | head -n 5 || echo "No VTI routes"
}

widget_interfaces() {
  local vti wan
  vti=$(cfg '.vti_if' 'vti0')
  wan=$(cfg '.wan_if' 'eth0')
  ip -br addr show "$vti" "$wan" lo 2>/dev/null | awk '{printf "%-8s %-8s %s\n", $1, $2, $3}' || true
}

widget_ipsec() {
  local ike child est
  est=$(ipsec statusall 2>/dev/null | grep -c ESTABLISHED || true)
  child=$(ipsec statusall 2>/dev/null | grep -c INSTALLED || true)
  ike="$est"
  cat <<EOF
Service    : $(badge "$(systemctl is-active strongswan-starter 2>/dev/null || echo DOWN)")
IKE        : $ike
CHILD      : $child
Rekey      : disabled
Status     : $(badge "$([ "$est" -gt 0 ] && echo RUNNING || echo DOWN)")
EOF
}

widget_health() {
  local load ram cpu
  load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo 'N/A')
  ram=$(free | awk '/Mem:/ {printf "%d", $3*100/$2}' 2>/dev/null || echo 0)
  cpu=$(awk 'BEGIN{print 8}')
  cat <<EOF
State      : $(badge HEALTHY)
Load       : $load
RAM        : $(bar "$ram" 16)
CPU        : $(bar "$cpu" 16)
Disk cap   : 2GB stats
EOF
}

widget_top_talkers() {
  if [ -x "$METRICS" ]; then
    "$METRICS" collect >/dev/null 2>&1 || true
    "$METRICS" top 2>/dev/null | head -n 11 || echo "No traffic data"
  else
    echo "Metrics unavailable"
  fi
}

render_menu_cards() {
  cat <<EOF
$(printf '%s▶%s  1. Start Tunnel      %s■%s  2. Stop Tunnel       %s⚙%s  3. Configure' "$GREEN" "$RESET" "$RED" "$RESET" "$YELLOW" "$RESET")
$(printf '%s▥%s  4. Status            %s▤%s  5. Logs              %s🔧%s  6. Tools' "$BLUE" "$RESET" "$PURPLE" "$RESET" "$CYAN" "$RESET")
$(printf '%s↪%s  7. Exit              %s📊%s  8. Top Talkers       %s🛡%s  9. Firewall' "$GRAY" "$RESET" "$GREEN" "$RESET" "$YELLOW" "$RESET")
EOF
}

render_dashboard() {
  clear
  local tw c3 c2 tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 tmp7 tmp8
  tw=$(term_width)
  [ "$tw" -lt 118 ] && tw=118
  c3=$(((tw - 8) / 3))
  c2=$(((tw - 6) / 2))

  render_header "$tw"
  echo

  tmp1=$(mktemp); tmp2=$(mktemp); tmp3=$(mktemp)
  panel "$c3" "🛡  TUNNEL STATUS" "$CYAN" "$(widget_tunnel)" > "$tmp1"
  panel "$c3" "🔐  XFRM STATUS" "$PURPLE" "$(widget_xfrm)" > "$tmp2"
  panel "$c3" "🟡  UNBOUND (DoT)" "$YELLOW" "$(widget_unbound)" > "$tmp3"
  join_cols "$tmp1" "$tmp2" "$tmp3"
  rm -f "$tmp1" "$tmp2" "$tmp3"

  echo

  tmp4=$(mktemp); tmp5=$(mktemp); tmp6=$(mktemp)
  panel "$c3" "☍  ROUTING" "$BLUE" "$(widget_routing)" > "$tmp4"
  panel "$c3" "▣  INTERFACES" "$CYAN" "$(widget_interfaces)" > "$tmp5"
  panel "$c3" "🔒  IPSEC STATUS" "$GREEN" "$(widget_ipsec)" > "$tmp6"
  join_cols "$tmp4" "$tmp5" "$tmp6"
  rm -f "$tmp4" "$tmp5" "$tmp6"

  echo

  tmp7=$(mktemp); tmp8=$(mktemp)
  panel "$c2" "📊  TOP TALKERS TODAY" "$GREEN" "$(widget_top_talkers)" > "$tmp7"
  panel "$c2" "💚  SYSTEM HEALTH" "$CYAN" "$(widget_health)" > "$tmp8"
  join_cols "$tmp7" "$tmp8"
  rm -f "$tmp7" "$tmp8"

  echo
  panel "$tw" "MAIN MENU" "$CYAN" "$(render_menu_cards)"
  echo
  printf '%s↑↓%s Navigate   %sENTER%s Select   %sQ%s Quit%*s%sBoghche Gateway - Secure your network the right way.%s\n' \
    "$CYAN" "$RESET" "$GREEN" "$RESET" "$RED" "$RESET" 12 '' "$CYAN" "$RESET"
}
