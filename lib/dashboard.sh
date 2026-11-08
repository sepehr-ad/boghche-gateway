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
repeat() { local n="$1"; local ch="$2"; printf '%*s' "$n" '' | tr ' ' "$ch"; }
strip_ansi() { sed -E $'s/\x1B\[[0-9;]*[A-Za-z]//g' <<< "$1"; }
visible_len() { local s; s=$(strip_ansi "$1"); printf '%s' "$s" | wc -m | tr -d ' '; }
trim_line() { printf '%s' "$1" | cut -c1-"$2"; }

pad_line() {
  local line="$1"
  local width="$2"
  local len pad
  len=$(visible_len "$line")
  if [ "$len" -gt "$width" ]; then
    line=$(trim_line "$(strip_ansi "$line")" "$width")
    len=$(visible_len "$line")
  fi
  pad=$((width - len))
  printf '%s%*s' "$line" "$pad" ''
}

cfg() {
  local key="$1"
  local def="${2:-N/A}"
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
  local pct="${1:-0}"
  local width="${2:-12}"
  local filled empty
  pct=${pct%%%}
  [[ "$pct" =~ ^[0-9]+$ ]] || pct=0
  [ "$pct" -gt 100 ] && pct=100
  filled=$((pct * width / 100))
  empty=$((width - filled))
  printf '%s' "$GREEN"
  repeat "$filled" '#'
  printf '%s' "$DIM"
  repeat "$empty" '-'
  printf '%s %s%%%s' "$RESET" "$pct" "$RESET"
}

plain_tunnel_state() { ipsec statusall 2>/dev/null | grep -q ESTABLISHED && echo CONNECTED || echo DOWN; }

panel() {
  local width="$1"
  local height="$2"
  local title="$3"
  local color="${4:-$CYAN}"
  local body="$5"
  local inner=$((width - 4))
  local lines line count=0
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
cpu_pct() {
  local a b idle1 total1 idle2 total2
  read -r _ a1 a2 a3 a4 a5 a6 a7 a8 _ < /proc/stat
  idle1=$((a4 + a5))
  total1=$((a1 + a2 + a3 + a4 + a5 + a6 + a7 + a8))
  sleep 0.1
  read -r _ b1 b2 b3 b4 b5 b6 b7 b8 _ < /proc/stat
  idle2=$((b4 + b5))
  total2=$((b1 + b2 + b3 + b4 + b5 + b6 + b7 + b8))
  if [ $((total2-total1)) -le 0 ]; then echo 0; else
    echo $((100 - (100 * (idle2-idle1) / (total2-total1))))
  fi
}

system_health_state() {
  local forward tunnel
  forward=$(sysctl -n net.ipv4.ip_forward 2>/dev/null || echo 0)
  tunnel=$(plain_tunnel_state)
  if [ "$forward" = "1" ] && [ "$tunnel" = "CONNECTED" ]; then
    echo HEALTHY
  else
    echo DEGRADED
  fi
}

render_header() {
  local width="$1"
  local inner=$((width-4))
  local host kernel uptime now tunnel ram cpu xfrm dns_state health line1 line2
  host=$(hostname)
  kernel=$(uname -r)
  uptime=$(uptime -p 2>/dev/null | sed 's/up //')
  now=$(date -u '+%Y-%m-%d %H:%M UTC')
  tunnel=$(plain_tunnel_state)
  ram=$(ram_pct)
  cpu=$(cpu_pct)
  health=$(system_health_state)
  xfrm=$(grep XfrmInTmplMismatch /proc/net/xfrm_stat 2>/dev/null | awk '{print $2}')
  xfrm=${xfrm:-0}
  dns_state=$(systemctl is-active unbound 2>/dev/null || echo DOWN)
  [ "$dns_state" = active ] && dns_state=RUNNING || dns_state=DOWN
  line1="${CYAN}${BOLD}BOGHCHE GATEWAY${RESET}  ${GRAY}Tunnel:${RESET} $(badge "$tunnel")  ${GRAY}CPU:${RESET} ${cpu}%  ${GRAY}RAM:${RESET} ${ram}%  $(badge "$health")"
  line2="${GRAY}Host:${RESET} $host  ${GRAY}Kernel:${RESET} $kernel  ${GRAY}Uptime:${RESET} $uptime  ${GRAY}XFRM tmpl total:${RESET} $xfrm  ${GRAY}DNS:${RESET} $(badge "$dns_state")  ${GRAY}Time:${RESET} $now"
  printf '%s+%s+%s\n' "$CYAN" "$(repeat $((width-2)) '=')" "$RESET"
  printf '%s|%s %s %s|%s\n' "$CYAN" "$RESET" "$(pad_line "$line1" "$inner")" "$CYAN" "$RESET"
  printf '%s|%s %s %s|%s\n' "$CYAN" "$RESET" "$(pad_line "$line2" "$inner")" "$CYAN" "$RESET"
  printf '%s+%s+%s\n' "$CYAN" "$(repeat $((width-2)) '=')" "$RESET"
}

widget_tunnel() {
  local state peer vti_ip remote sas dpd
  state=$(plain_tunnel_state)
  peer=$(cfg '.right' 'N/A')
  vti_ip=$(cfg '.vti_addr' 'N/A')
  remote=$(cfg '.vti_remote' 'N/A')
  dpd="$(cfg '.dpd_delay' '10s')/$(cfg '.dpd_timeout' '30s')"
  sas=$(ipsec statusall 2>/dev/null | grep -c 'INSTALLED' || true)
  cat <<EOF
Peer       $peer
Local VTI  $vti_ip
Remote GW  $remote
DPD cfg    $dpd
SA         ${sas}/1
Status     $(badge "$state")
EOF
}

widget_xfrm() {
  local mismatch seqerr states policies
  mismatch=$(grep XfrmInTmplMismatch /proc/net/xfrm_stat 2>/dev/null | awk '{print $2}')
  seqerr=$(grep XfrmInStateSeqError /proc/net/xfrm_stat 2>/dev/null | awk '{print $2}')
  mismatch=${mismatch:-0}
  seqerr=${seqerr:-0}
  states=$(ip xfrm state 2>/dev/null | grep -c '^src ' || true)
  policies=$(ip xfrm policy 2>/dev/null | grep -c '^src ' || true)
  cat <<EOF
Policies   $policies
States     $states
Tmpl total $mismatch
Seq total  $seqerr
Counters   cumulative
Status     $(badge "$([ "$states" -gt 0 ] && echo OK || echo DOWN)")
EOF
}

widget_dns() {
  local state listen upstream dot
  state=$(systemctl is-active unbound 2>/dev/null || true)
  [ "$state" = active ] && state=RUNNING || state=DISABLED
  listen=$(cfg '.unbound_listen_ip' "$(cfg '.vti_addr' 'N/A' | cut -d/ -f1)")
  upstream=$(jq -r '.dns_upstreams // [] | .[0] // "N/A"' "$CONFIG" 2>/dev/null || echo N/A)
  if [[ "$upstream" == *"@853"* ]]; then dot="configured"; else dot="not configured"; fi
  cat <<EOF
Listen     ${listen:-N/A}
Port       53 -> 853
Upstream   ${upstream:-N/A}
DoT cfg    $dot
Config     boghche.conf
Status     $(badge "$state")
EOF
}

widget_top_talkers() {
  if [ -x "$METRICS" ]; then
    "$METRICS" collect >/dev/null 2>&1 || true
    local out
    out=$("$METRICS" top 2>/dev/null | awk 'NR>1{print $2 "   " $3 " " $4}' | head -n 5 || true)
    [ -n "$out" ] && printf '%s\n' "$out" || echo "No traffic data yet"
  else
    echo "Metrics unavailable"
  fi
}

widget_health() {
  local load ram cpu health
  load=$(cut -d' ' -f1-3 /proc/loadavg 2>/dev/null || echo N/A)
  ram=$(ram_pct)
  cpu=$(cpu_pct)
  health=$(system_health_state)
  cat <<EOF
Load       $load
CPU        $(bar "$cpu" 14)
RAM        $(bar "$ram" 14)
Disk cap   2GB rolling
Stats      /var/lib/boghche/stats
Status     $(badge "$health")
EOF
}

widget_interfaces() {
  local vti wan data
  vti=$(cfg '.vti_if' 'vti0')
  wan=$(cfg '.wan_if' 'eth0')
  data=$(ip -br addr 2>/dev/null | awk -v vti="$vti" -v wan="$wan" '$1==vti || $1==wan {printf "%s  %s  %s\n", $1, $2, $3}')
  [ -n "$data" ] && printf '%s\n' "$data" || echo "No interface telemetry"
}

render_footer_menu() {
  local width="$1"
  local inner=$((width-4))
  local line="${GREEN}[1] Tunnel${RESET}  ${CYAN}[2] Monitor${RESET}  ${YELLOW}[3] Firewall${RESET}  ${PURPLE}[4] DNS${RESET}  ${BLUE}[5] Logs${RESET}  ${GRAY}[6] Maintenance${RESET}  ${RED}[Q] Quit${RESET}"
  printf '%s+%s+%s\n' "$DIM" "$(repeat $((width-2)) '-')" "$RESET"
  printf '%s|%s %s %s|%s\n' "$DIM" "$RESET" "$(pad_line "$line" "$inner")" "$DIM" "$RESET"
  printf '%s+%s+%s\n' "$DIM" "$(repeat $((width-2)) '-')" "$RESET"
}

render_dashboard() {
  clear
  local tw c3 c2 tmp1 tmp2 tmp3 tmp4 tmp5 tmp6
  tw=$(term_width)
  [ "$tw" -lt 118 ] && tw=118
  [ "$tw" -gt 148 ] && tw=148
  c3=$(((tw - 8) / 3))
  c2=$(((tw - 6) / 2))

  render_header "$tw"
  echo

  tmp1=$(mktemp); tmp2=$(mktemp); tmp3=$(mktemp)
  panel "$c3" 6 "TUNNEL" "$CYAN" "$(widget_tunnel)" > "$tmp1"
  panel "$c3" 6 "XFRM" "$PURPLE" "$(widget_xfrm)" > "$tmp2"
  panel "$c3" 6 "DNS SERVICE" "$YELLOW" "$(widget_dns)" > "$tmp3"
  join_cols "$tmp1" "$tmp2" "$tmp3"
  rm -f "$tmp1" "$tmp2" "$tmp3"
  echo

  tmp4=$(mktemp); tmp5=$(mktemp)
  panel "$c2" 6 "TOP TALKERS TODAY" "$GREEN" "$(widget_top_talkers)" > "$tmp4"
  panel "$c2" 6 "SYSTEM HEALTH" "$CYAN" "$(widget_health)" > "$tmp5"
  join_cols "$tmp4" "$tmp5"
  rm -f "$tmp4" "$tmp5"
  echo

  tmp6=$(mktemp)
  panel "$tw" 2 "INTERFACES" "$BLUE" "$(widget_interfaces)" > "$tmp6"
  cat "$tmp6"
  rm -f "$tmp6"

  echo
  render_footer_menu "$tw"
  echo
  printf '%sDashboard%s is monitoring-only. Use service menus for configuration and troubleshooting.%s\n' "$DIM" "$RESET" "$RESET"
}
