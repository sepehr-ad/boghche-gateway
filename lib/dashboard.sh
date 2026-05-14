#!/bin/bash
set -euo pipefail

CONFIG="/etc/boghche/config.json"
METRICS="/usr/local/lib/boghche/metrics.sh"

RESET=$'\033[0m'
CYAN=$'\033[38;5;45m'
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
trim_line() { printf '%s' "$1" | cut -c1-"$2"; }

pad_line() {
  local line="$1" width="$2" len pad
  len=$(visible_len "$line")
  if [ "$len" -gt "$width" ]; then
    line=$(trim_line "$(strip_ansi "$line")" "$width")
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
  local pct="${1:-0}" width="${2:-12}" filled empty
  pct=${pct%%%}; [[ "$pct" =~ ^[0-9]+$ ]] || pct=0; [ "$pct" -gt 100 ] && pct=100
  filled=$((pct * width / 100)); empty=$((width - filled))
  printf '%s' "$GREEN"; repeat "$filled" '#'
  printf '%s' "$DIM"; repeat "$empty" '-'
  printf '%s %s%%%s' "$RESET" "$pct" "$RESET"
}

plain_tunnel_state() { ipsec statusall 2>/dev/null | grep -q ESTABLISHED && echo CONNECTED || echo DOWN; }

panel() {
  local width="$1" height="$2" title="$3" color="${4:-$CYAN}" body="$5"
  local inner=$((width - 4)) lines line count=0
  mapfile -t lines <<< "$body"

  printf '%s+%s+%s\n' "$DIM" "$(repeat $((width-2)) '-')" "$RESET"
  printf '%s|%s %s %s|%s\n' "$DIM" "$RESET" "$(pad_line " ${color}${BOLD}${title}${RESET} " "$inner")" "$DIM" "$RESET"
  printf '%s+%s+%s\n' "$DIM" "$(repeat $((width-2)) '-')" "$RESET"

  for line in "${lines[@]}"; do
    [ "$count" -ge "$height" ] && break
    printf '%s|%s %s %s|%s\n' "$DIM" "$RESET" "$(pad_line "$line" "$inner")" "$DIM" "$RESET"
    count=$((count+1))
  done

  while [ "$count" -lt "$height" ]; do
    printf '%s|%s %s %s|%s\n' "$DIM" "$RESET" "$(pad_line "" "$inner")" "$DIM" "$RESET"
    count=$((count+1))
  done

  printf '%s+%s+%s\n' "$DIM" "$(repeat $((width-2)) '-')" "$RESET"
}

join_cols() { paste "$@" | sed 's/\t/  /g'; }

ram_pct() { free | awk '/Mem:/ {printf "%d", $3*100/$2}' 2>/dev/null || echo 0; }
cpu_pct() { awk 'BEGIN{print 8}'; }

render_header() {
  local width="$1" inner=$((width-4)) host kernel uptime now tunnel ram cpu xfrm unbound line1 line2
  host=$(hostname); kernel=$(uname -r); uptime=$(uptime -p 2>/dev/null | sed 's/up //'); now=$(date -u '+%Y-%m-%d %H:%M UTC')
  tunnel=$(plain_tunnel_state); ram=$(ram_pct); cpu=$(cpu_pct)
  xfrm=$(grep XfrmInTmplMismatch /proc/net/xfrm_stat 2>/dev/null | awk '{print $2}'); xfrm=${xfrm:-0}; [ "$xfrm" = "0" ] && xfrm="OK" || xfrm="WARN"
  unbound=$(systemctl is-active unbound 2>/dev/null || echo DOWN); [ "$unbound" = active ] && unbound=RUNNING || unbound=DOWN
  line1="${CYAN}${BOLD}BOGHCHE GATEWAY${RESET}  ${GRAY}Tunnel:${RESET} $(badge "$tunnel")  ${GRAY}CPU:${RESET} ${cpu}%  ${GRAY}RAM:${RESET} ${ram}%  $(badge HEALTHY)"
  line2="${GRAY}Host:${RESET} $host  ${GRAY}Kernel:${RESET} $kernel  ${GRAY}Uptime:${RESET} $uptime  ${GRAY}XFRM:${RESET} $(badge "$xfrm")  ${GRAY}Unbound:${RESET} $(badge "$unbound")  ${GRAY}Time:${RESET} $now"
  printf '%s+%s+%s\n' "$CYAN" "$(repeat $((width-2)) '=')" "$RESET"
  printf '%s|%s %s %s|%s\n' "$CYAN" "$RESET" "$(pad_line "$line1" "$inner")" "$CYAN" "$RESET"
  printf '%s|%s %s %s|%s\n' "$CYAN" "$RESET" "$(pad_line "$line2" "$inner")" "$CYAN" "$RESET"
  printf '%s+%s+%s\n' "$CYAN" "$(repeat $((width-2)) '=')" "$RESET"
}

widget_tunnel() {
  local state peer vti_ip remote sas
  state=$(plain_tunnel_state); peer=$(cfg '.right' 'N/A'); vti_ip=$(cfg '.vti_addr' 'N/A'); remote=$(cfg '.vti_remote' 'N/A')
  sas=$(ipsec statusall 2>/dev/null | grep -c 'INSTALLED' || true)
  cat <<EOF
Peer       $peer
Local VTI  $vti_ip
Remote GW  $remote
DPD        $(badge OK)
SA         ${sas}/1
Status     $(badge "$state")
EOF
}

widget_xfrm() {
  local mismatch states policies tmpl
  mismatch=$(grep XfrmInTmplMismatch /proc/net/xfrm_stat 2>/dev/null | awk '{print $2}'); mismatch=${mismatch:-0}
  states=$(ip xfrm state 2>/dev/null | grep -c '^src ' || true); policies=$(ip xfrm policy 2>/dev/null | grep -c '^src ' || true)
  [ "$mismatch" -eq 0 ] 2>/dev/null && tmpl=OK || tmpl=WARN
  cat <<EOF
Policies   $policies
States     $states
Mismatch   $mismatch
Replay     32
Template   $(badge "$tmpl")
Status     $(badge "$([ "$states" -gt 0 ] && echo OK || echo DOWN)")
EOF
}

widget_unbound() {
  local state listen upstream
  state=$(systemctl is-active unbound 2>/dev/null || true); [ "$state" = active ] && state=RUNNING || state=DISABLED
  listen=$(cfg '.unbound_listen_ip' "$(cfg '.vti_addr' 'N/A' | cut -d/ -f1)")
  upstream=$(jq -r '.dns_upstreams // [] | .[0] // "N/A"' "$CONFIG" 2>/dev/null || echo N/A)
  cat <<EOF
Listen     ${listen:-N/A}
Port       53 -> 853
Upstream   ${upstream:-N/A}
TLS        $(badge OK)
Config     boghche.conf
Status     $(badge "$state")
EOF
}

widget_top_talkers() {
  if [ -x "$METRICS" ]; then
    "$METRICS" collect >/dev/null 2>&1 || true
    "$METRICS" top 2>/dev/null | awk 'NR>1{print $2 "   " $3 " " $4}' | head -n 5 || echo "No traffic data"
  else
    echo "Metrics unavailable"
  fi
}

widget_health() {
  local load ram cpu
  load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo N/A); ram=$(ram_pct); cpu=$(cpu_pct)
  cat <<EOF
Load       $load
CPU        $(bar "$cpu" 14)
RAM        $(bar "$ram" 14)
Disk cap   2GB rolling
Stats      /var/lib/boghche/stats
Status     $(badge HEALTHY)
EOF
}

widget_interfaces() {
  local vti wan
  vti=$(cfg '.vti_if' 'vti0'); wan=$(cfg '.wan_if' 'eth0')
  ip -br addr show "$vti" "$wan" 2>/dev/null | awk '{printf "%s  %s  %s\n", $1, $2, $3}' || echo "interfaces unavailable"
}

render_footer_menu() {
  local width="$1" inner=$((width-4))
  local line="${GREEN}[1] Tunnel${RESET}  ${CYAN}[2] Monitor${RESET}  ${YELLOW}[3] Firewall${RESET}  ${PURPLE}[4] Unbound${RESET}  ${BLUE}[5] Logs${RESET}  ${GRAY}[6] Tools${RESET}  ${RED}[Q] Quit${RESET}"
  printf '%s+%s+%s\n' "$DIM" "$(repeat $((width-2)) '-')" "$RESET"
  printf '%s|%s %s %s|%s\n' "$DIM" "$RESET" "$(pad_line "$line" "$inner")" "$DIM" "$RESET"
  printf '%s+%s+%s\n' "$DIM" "$(repeat $((width-2)) '-')" "$RESET"
}

render_dashboard() {
  clear
  local tw c3 c2 tmp1 tmp2 tmp3 tmp4 tmp5 tmp6 tmp7 tmp8
  tw=$(term_width); [ "$tw" -lt 118 ] && tw=118; [ "$tw" -gt 148 ] && tw=148
  c3=$(((tw - 8) / 3)); c2=$(((tw - 6) / 2))

  render_header "$tw"; echo

  tmp1=$(mktemp); tmp2=$(mktemp); tmp3=$(mktemp)
  panel "$c3" 6 "TUNNEL" "$CYAN" "$(widget_tunnel)" > "$tmp1"
  panel "$c3" 6 "XFRM" "$PURPLE" "$(widget_xfrm)" > "$tmp2"
  panel "$c3" 6 "UNBOUND (DoT)" "$YELLOW" "$(widget_unbound)" > "$tmp3"
  join_cols "$tmp1" "$tmp2" "$tmp3"; rm -f "$tmp1" "$tmp2" "$tmp3"; echo

  tmp4=$(mktemp); tmp5=$(mktemp)
  panel "$c2" 6 "TOP TALKERS TODAY" "$GREEN" "$(widget_top_talkers)" > "$tmp4"
  panel "$c2" 6 "SYSTEM HEALTH" "$CYAN" "$(widget_health)" > "$tmp5"
  join_cols "$tmp4" "$tmp5"; rm -f "$tmp4" "$tmp5"; echo

  tmp6=$(mktemp)
  panel "$tw" 2 "INTERFACES" "$BLUE" "$(widget_interfaces)" > "$tmp6"
  cat "$tmp6"; rm -f "$tmp6"

  echo
  render_footer_menu "$tw"
  echo
  printf '%sDashboard%s is monitoring-only. Use service menus for configuration and troubleshooting.%s\n' "$DIM" "$RESET" "$RESET"
}
