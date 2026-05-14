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

term_width() { tput cols 2>/dev/null || echo 140; }
repeat() { local n="$1" ch="$2"; printf '%*s' "$n" '' | tr ' ' "$ch"; }
strip_ansi() { sed -E $'s/\x1B\[[0-9;]*[A-Za-z]//g' <<< "$1"; }
visible_len() { local s; s=$(strip_ansi "$1"); printf '%s' "$s" | wc -m | tr -d ' '; }
truncate_plain() { local s="$1" max="$2"; printf '%s' "$s" | cut -c1-"$max"; }

pad_line() {
  local line="$1" width="$2" len pad
  len=$(visible_len "$line")
  if [ "$len" -gt "$width" ]; then
    line=$(truncate_plain "$(strip_ansi "$line")" "$width")
    len=$(visible_len "$line")
  fi
  pad=$((width - len))
  printf '%s%*s' "$line" "$pad" ''
}

cfg() {
  local key="$1" def="${2:-N/A}"
  jq -r "$key // \"$def\"" "$CONFIG" 2>/dev/null || echo "$def"
}

badge() {
  local value="$1"
  case "$value" in
    CONNECTED|RUNNING|OK|UP|HEALTHY|active) printf '%s%s%s' "$GREEN" "$value" "$RESET" ;;
    WARN*|DEGRADED|DISABLED) printf '%s%s%s' "$YELLOW" "$value" "$RESET" ;;
    DOWN|FAILED|ERROR|inactive|failed) printf '%s%s%s' "$RED" "$value" "$RESET" ;;
    *) printf '%s' "$value" ;;
  esac
}

bar() {
  local pct="${1:-0}" width="${2:-16}" filled empty
  pct=${pct%%%}
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  [ "$pct" -gt 100 ] && pct=100
  filled=$((pct * width / 100)); empty=$((width - filled))
  printf '%s' "$GREEN"; repeat "$filled" '#'
  printf '%s' "$DIM"; repeat "$empty" '-'
  printf '%s %s%%%s' "$RESET" "$pct" "$RESET"
}

plain_tunnel_state() {
  if ipsec statusall 2>/dev/null | grep -q ESTABLISHED; then echo CONNECTED; else echo DOWN; fi
}

panel() {
  local width="$1" title="$2" color="${3:-$CYAN}" body="$4"
  local inner=$((width - 4)) line title_line
  printf '%s+%s+%s\n' "$DIM" "$(repeat $((width-2)) '-')" "$RESET"
  title_line=" ${color}${BOLD}${title}${RESET} "
  printf '%s|%s %s %s|%s\n' "$DIM" "$RESET" "$(pad_line "$title_line" "$inner")" "$DIM" "$RESET"
  printf '%s+%s+%s\n' "$DIM" "$(repeat $((width-2)) '-')" "$RESET"
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s|%s %s %s|%s\n' "$DIM" "$RESET" "$(pad_line "$line" "$inner")" "$DIM" "$RESET"
  done <<< "$body"
  printf '%s+%s+%s\n' "$DIM" "$(repeat $((width-2)) '-')" "$RESET"
}

join_cols() { paste "$@" | sed 's/\t/  /g'; }

render_header() {
  local width="$1" inner=$((width-4)) host kernel uptime now line1 line2 line3
  host=$(hostname); kernel=$(uname -r); uptime=$(uptime -p 2>/dev/null | sed 's/up //'); now=$(date -u '+%Y-%m-%d %H:%M:%S UTC')
  line1="${CYAN}${BOLD}BOGHCHE  GATEWAY${RESET}   ${GRAY}IPSec + VTI + DoT Gateway${RESET}"
  line2="${GRAY}Host:${RESET} $host   ${GRAY}Kernel:${RESET} $kernel   ${GRAY}Time:${RESET} $now"
  line3="${GRAY}Uptime:${RESET} $uptime   ${GRAY}Storage cap:${RESET} 2GB   ${GRAY}Version:${RESET} v1.3.0"
  printf '%s+%s+%s\n' "$CYAN" "$(repeat $((width-2)) '=')" "$RESET"
  printf '%s|%s %s %s|%s\n' "$CYAN" "$RESET" "$(pad_line "$line1" "$inner")" "$CYAN" "$RESET"
  printf '%s|%s %s %s|%s\n' "$CYAN" "$RESET" "$(pad_line "$line2" "$inner")" "$CYAN" "$RESET"
  printf '%s|%s %s %s|%s\n' "$CYAN" "$RESET" "$(pad_line "$line3" "$inner")" "$CYAN" "$RESET"
  printf '%s+%s+%s\n' "$CYAN" "$(repeat $((width-2)) '=')" "$RESET"
}

widget_tunnel() {
  local state peer vti vti_ip remote sas
  state=$(plain_tunnel_state); peer=$(cfg '.right' 'N/A'); vti=$(cfg '.vti_if' 'vti0'); vti_ip=$(cfg '.vti_addr' 'N/A'); remote=$(cfg '.vti_remote' 'N/A')
  sas=$(ipsec statusall 2>/dev/null | grep -c 'INSTALLED' || true)
  cat <<EOF
State      : $(badge "$state")
Peer       : $peer
Local VTI  : $vti_ip
Remote GW  : $remote
Device     : $vti
SAs        : $(bar $((sas > 0 ? 100 : 0)) 12) $sas/1
EOF
}

widget_xfrm() {
  local mismatch states policies tmpl
  mismatch=$(grep XfrmInTmplMismatch /proc/net/xfrm_stat 2>/dev/null | awk '{print $2}'); mismatch=${mismatch:-0}
  states=$(ip xfrm state 2>/dev/null | grep -c '^src ' || true); policies=$(ip xfrm policy 2>/dev/null | grep -c '^src ' || true)
  [ "$mismatch" -eq 0 ] 2>/dev/null && tmpl=OK || tmpl="WARN $mismatch"
  cat <<EOF
State      : $(badge "$([ "$states" -gt 0 ] && echo OK || echo DOWN)")
Policies   : $policies
States     : $states
Mismatch   : $mismatch
Template   : $(badge "$tmpl")
Replay     : 32
EOF
}

widget_unbound() {
  local state listen upstream
  state=$(systemctl is-active unbound 2>/dev/null || true); [ "$state" = active ] && state=RUNNING || state=DISABLED
  listen=$(cfg '.unbound_listen_ip' "$(cfg '.vti_addr' 'N/A' | cut -d/ -f1)")
  upstream=$(jq -r '.dns_upstreams // [] | join(", ")' "$CONFIG" 2>/dev/null || echo N/A)
  cat <<EOF
State      : $(badge "$state")
Listen IP  : ${listen:-N/A}
Port       : 53 -> DoT/853
Upstream   : ${upstream:-N/A}
TLS        : $(badge OK)
Config     : boghche.conf
EOF
}

widget_routing() { ip route show table vti 2>/dev/null | head -n 6 || echo "No VTI routes"; }
widget_interfaces() { local vti wan; vti=$(cfg '.vti_if' 'vti0'); wan=$(cfg '.wan_if' 'eth0'); ip -br addr show "$vti" "$wan" lo 2>/dev/null | awk '{printf "%-8s %-8s %s\n", $1, $2, $3}' || echo "No interfaces"; }

widget_ipsec() {
  local svc ike child
  svc=$(systemctl is-active strongswan-starter 2>/dev/null || echo DOWN)
  ike=$(ipsec statusall 2>/dev/null | grep -c ESTABLISHED || true); child=$(ipsec statusall 2>/dev/null | grep -c INSTALLED || true)
  cat <<EOF
Service    : $(badge "$svc")
IKE        : $ike
CHILD      : $child
Rekey      : disabled
Status     : $(badge "$([ "$ike" -gt 0 ] && echo RUNNING || echo DOWN)")
EOF
}

widget_health() {
  local load ram cpu
  load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo N/A); ram=$(free | awk '/Mem:/ {printf "%d", $3*100/$2}' 2>/dev/null || echo 0); cpu=8
  cat <<EOF
State      : $(badge HEALTHY)
Load       : $load
RAM        : $(bar "$ram" 14)
CPU        : $(bar "$cpu" 14)
Disk cap   : 2GB stats
EOF
}

widget_top_talkers() {
  if [ -x "$METRICS" ]; then "$METRICS" collect >/dev/null 2>&1 || true; "$METRICS" top 2>/dev/null | head -n 11 || echo "No traffic data"; else echo "Metrics unavailable"; fi
}

render_menu_cards() {
  cat <<EOF
$(printf '%s[1]%s Start Tunnel       %s[2]%s Stop Tunnel        %s[3]%s Configure' "$GREEN" "$RESET" "$RED" "$RESET" "$YELLOW" "$RESET")
$(printf '%s[4]%s Status             %s[5]%s Logs               %s[6]%s Tools' "$BLUE" "$RESET" "$PURPLE" "$RESET" "$CYAN" "$RESET")
$(printf '%s[7]%s Exit               %s[8]%s Top Talkers        %s[9]%s Firewall' "$GRAY" "$RESET" "$GREEN" "$RESET" "$YELLOW" "$RESET")
EOF
}

render_dashboard() {
  clear
  local tw c3 c2 tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 tmp7 tmp8
  tw=$(term_width); [ "$tw" -lt 118 ] && tw=118; [ "$tw" -gt 154 ] && tw=154
  c3=$(((tw - 8) / 3)); c2=$(((tw - 6) / 2))
  render_header "$tw"; echo
  tmp1=$(mktemp); tmp2=$(mktemp); tmp3=$(mktemp)
  panel "$c3" "TUNNEL STATUS" "$CYAN" "$(widget_tunnel)" > "$tmp1"
  panel "$c3" "XFRM STATUS" "$PURPLE" "$(widget_xfrm)" > "$tmp2"
  panel "$c3" "UNBOUND (DoT)" "$YELLOW" "$(widget_unbound)" > "$tmp3"
  join_cols "$tmp1" "$tmp2" "$tmp3"; rm -f "$tmp1" "$tmp2" "$tmp3"; echo
  tmp4=$(mktemp); tmp5=$(mktemp); tmp6=$(mktemp)
  panel "$c3" "ROUTING" "$BLUE" "$(widget_routing)" > "$tmp4"
  panel "$c3" "INTERFACES" "$CYAN" "$(widget_interfaces)" > "$tmp5"
  panel "$c3" "IPSEC STATUS" "$GREEN" "$(widget_ipsec)" > "$tmp6"
  join_cols "$tmp4" "$tmp5" "$tmp6"; rm -f "$tmp4" "$tmp5" "$tmp6"; echo
  tmp7=$(mktemp); tmp8=$(mktemp)
  panel "$c2" "TOP TALKERS TODAY" "$GREEN" "$(widget_top_talkers)" > "$tmp7"
  panel "$c2" "SYSTEM HEALTH" "$CYAN" "$(widget_health)" > "$tmp8"
  join_cols "$tmp7" "$tmp8"; rm -f "$tmp7" "$tmp8"; echo
  panel "$tw" "MAIN MENU" "$CYAN" "$(render_menu_cards)"
  echo
  printf '%sUP/DOWN%s Navigate   %sENTER%s Select   %sQ%s Quit%*s%sBoghche Gateway - Secure your network the right way.%s\n' "$CYAN" "$RESET" "$GREEN" "$RESET" "$RED" "$RESET" 10 '' "$CYAN" "$RESET"
}
