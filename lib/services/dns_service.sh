#!/bin/bash
set -euo pipefail

CONFIG="/etc/boghche/config.json"

_dns_pause() { echo; gum confirm "Return?" >/dev/null 2>&1 || true; }
_dns_ask() { local label="$1" default="${2:-}"; [ -n "$default" ] && gum input --value "$default" --placeholder "$label" || gum input --placeholder "$label"; }
_dns_vti_ip() { jq -r '.unbound_listen_ip // (.vti_addr | split("/")[0]) // "127.0.0.1"' "$CONFIG" 2>/dev/null || echo 127.0.0.1; }
_dns_save_provider() {
  local provider="$1" p="$2" s="$3" tmp
  [ -f "$CONFIG" ] || { gum style --foreground 196 "No tunnel config found. Configure tunnel first."; return 1; }
  tmp=$(mktemp)
  jq --arg p "$p" --arg s "$s" '.unbound=true | .dns_upstreams=[$p,$s] | .unbound_listen_ip=(.unbound_listen_ip // (.vti_addr | split("/")[0]))' "$CONFIG" > "$tmp"
  mv "$tmp" "$CONFIG"
  /usr/local/lib/boghche/unbound.sh || true
  systemctl restart unbound || true
  gum style --foreground 46 "Secure DNS provider enabled: $provider"
}

dns_enable_secure() {
  [ -f "$CONFIG" ] || { gum style --foreground 196 "No tunnel config found. Configure tunnel first."; return; }
  tmp=$(mktemp)
  jq '.unbound=true | .unbound_listen_ip=(.unbound_listen_ip // (.vti_addr | split("/")[0])) | .dns_upstreams=(.dns_upstreams // ["8.8.8.8@853#dns.google","8.8.4.4@853#dns.google"])' "$CONFIG" > "$tmp"
  mv "$tmp" "$CONFIG"
  /usr/local/lib/boghche/unbound.sh || true
  systemctl restart unbound || true
  gum style --foreground 46 "Secure DNS enabled on tunnel IP: $(_dns_vti_ip)"
}

dns_select_provider() {
  clear; gum style --foreground 220 --bold "Select Secure DNS Provider"
  provider=$(gum choose "Google" "Cloudflare" "Quad9" "Custom")
  case "$provider" in
    Google) _dns_save_provider Google "8.8.8.8@853#dns.google" "8.8.4.4@853#dns.google" ;;
    Cloudflare) _dns_save_provider Cloudflare "1.1.1.1@853#cloudflare-dns.com" "1.0.0.1@853#cloudflare-dns.com" ;;
    Quad9) _dns_save_provider Quad9 "9.9.9.9@853#dns.quad9.net" "149.112.112.112@853#dns.quad9.net" ;;
    Custom)
      p=$(_dns_ask "Primary DoT upstream, e.g. 8.8.8.8@853#dns.google")
      s=$(_dns_ask "Secondary DoT upstream")
      [ -n "$p" ] && _dns_save_provider Custom "$p" "$s"
      ;;
  esac
}

dns_test() {
  clear; gum style --foreground 45 --bold "DNS Resolution Test"
  domain=$(_dns_ask "Domain to resolve" "google.com")
  listen=$(_dns_vti_ip)
  echo "Testing $domain using DNS listener $listen"
  echo
  if command -v dig >/dev/null 2>&1; then
    dig @"$listen" "$domain" +short || true
  else
    nslookup "$domain" "$listen" || true
  fi
}

dns_summary() {
  clear; gum style --foreground 45 --bold "DNS Service Summary"
  if [ ! -f "$CONFIG" ]; then echo "No config found."; return; fi
  echo "Enabled  : $(jq -r '.unbound // false' "$CONFIG")"
  echo "Listen   : $(_dns_vti_ip)"
  echo "Upstream : $(jq -r '.dns_upstreams // [] | join(", ")' "$CONFIG")"
  echo "Service  : $(systemctl is-active unbound 2>/dev/null || echo unknown)"
  echo
  [ -f /etc/unbound/unbound.conf.d/boghche.conf ] && echo "Config   : /etc/unbound/unbound.conf.d/boghche.conf" || echo "Config   : not generated yet"
}

dns_repair() {
  clear; gum style --foreground 45 --bold "Repair DNS"
  /usr/local/lib/boghche/unbound.sh || true
  systemctl restart unbound || true
  unbound-checkconf || true
  gum style --foreground 46 "DNS rebuilt and restarted."
}

dns_menu() {
  while true; do
    clear
    gum style --foreground 220 --bold "DNS Service Center"
    choice=$(gum choose "Enable secure DNS" "Select DNS provider" "Test DNS" "Repair DNS" "View DNS summary" "Back")
    case "$choice" in
      "Enable secure DNS") dns_enable_secure; _dns_pause ;;
      "Select DNS provider") dns_select_provider; _dns_pause ;;
      "Test DNS") dns_test; _dns_pause ;;
      "Repair DNS") dns_repair; _dns_pause ;;
      "View DNS summary") dns_summary; _dns_pause ;;
      "Back") return ;;
    esac
  done
}
