#!/bin/bash
set -euo pipefail

_pause(){ echo; gum confirm "Return?" >/dev/null 2>&1 || true; }

monitor_top_talkers() {
  clear
  gum style --foreground 45 --bold "Top Talkers"
  /usr/local/lib/boghche/metrics.sh collect || true
  /usr/local/lib/boghche/metrics.sh top || true
}

monitor_tunnel() {
  clear
  gum style --foreground 45 --bold "Tunnel Telemetry"
  ipsec statusall | grep -E 'ESTABLISHED|INSTALLED|bytes|rekeying' || true
}

monitor_xfrm() {
  clear
  gum style --foreground 45 --bold "XFRM Health"
  grep '^Xfrm' /proc/net/xfrm_stat || true
}

monitor_interfaces() {
  clear
  gum style --foreground 45 --bold "Interface Traffic"
  ip -s link show || true
}

monitor_menu() {
  while true; do
    clear
    gum style --foreground 45 --bold "Operations Center"
    choice=$(gum choose "Top talkers" "Tunnel telemetry" "XFRM health" "Interface traffic" "Back")
    case "$choice" in
      "Top talkers") monitor_top_talkers; _pause ;;
      "Tunnel telemetry") monitor_tunnel; _pause ;;
      "XFRM health") monitor_xfrm; _pause ;;
      "Interface traffic") monitor_interfaces; _pause ;;
      "Back") return ;;
    esac
  done
}
