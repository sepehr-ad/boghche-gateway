#!/bin/bash
set -euo pipefail

CONFIG="/etc/boghche/config.json"
RULES_DIR="/etc/boghche/rules"
RULES_FILE="${RULES_DIR}/firewall.jsonl"

fw_init() {
  mkdir -p "$RULES_DIR"
  touch "$RULES_FILE"
}

fw_ask() {
  local label="$1"
  local default="${2:-}"
  if [ -n "$default" ]; then
    gum input --value "$default" --placeholder "$label"
  else
    gum input --placeholder "$label"
  fi
}

fw_record() {
  fw_init
  jq -cn \
    --arg ts "$(date -u +%FT%TZ)" \
    --arg action "$1" \
    --arg source "$2" \
    --arg destination "$3" \
    --arg proto "$4" \
    --arg port "$5" \
    '{time:$ts,action:$action,source:$source,destination:$destination,protocol:$proto,port:$port}' >> "$RULES_FILE"
}

fw_allow_access() {
  clear
  gum style --foreground 46 --bold "Allow Access"
  src=$(fw_ask "Source IP/subnet" "192.168.0.0/16")
  dst=$(fw_ask "Destination IP/subnet or any" "any")
  proto=$(gum choose "tcp" "udp" "any")
  port=$(fw_ask "Destination port, empty for any")

  [ -z "$src" ] && return

  if [ -n "$port" ] && [ "$proto" != "any" ]; then
    ufw allow from "$src" to any port "$port" proto "$proto" || true
  else
    ufw allow from "$src" || true
  fi

  fw_record "allow" "$src" "$dst" "$proto" "${port:-any}"
  gum style --foreground 46 "Created allow policy: $src -> $dst ${proto}/${port:-any}"
}

fw_restrict_access() {
  clear
  gum style --foreground 196 --bold "Restrict Access"
  src=$(fw_ask "Source IP/subnet to restrict")
  proto=$(gum choose "tcp" "udp" "any")
  port=$(fw_ask "Port, empty for all")

  [ -z "$src" ] && return

  if [ -n "$port" ] && [ "$proto" != "any" ]; then
    ufw deny from "$src" to any port "$port" proto "$proto" || true
  else
    ufw deny from "$src" || true
  fi

  fw_record "restrict" "$src" "any" "$proto" "${port:-any}"
  gum style --foreground 46 "Created restrict policy: $src ${proto}/${port:-any}"
}

fw_enable_nat() {
  clear
  gum style --foreground 45 --bold "Enable NAT for Subnet"
  [ -f "$CONFIG" ] || { gum style --foreground 196 "No config found."; return; }
  subnet=$(fw_ask "Subnet to give internet/NAT access" "192.168.0.0/16")
  [ -z "$subnet" ] && return
  tmp=$(mktemp)
  jq --arg subnet "$subnet" '.lans = ((.lans // []) + [$subnet] | unique) | .nat = true' "$CONFIG" > "$tmp"
  mv "$tmp" "$CONFIG"
  systemctl restart boghche || true
  fw_record "nat-enable" "$subnet" "internet" "any" "any"
  gum style --foreground 46 "NAT enabled for $subnet"
}

fw_repair_forwarding() {
  clear
  gum style --foreground 45 --bold "Repair Tunnel Forwarding"
  vti=$(jq -r '.vti_if // "vti0"' "$CONFIG" 2>/dev/null || echo vti0)
  wan=$(jq -r '.wan_if // "eth0"' "$CONFIG" 2>/dev/null || echo eth0)
  iptables -C FORWARD -i "$vti" -o "$wan" -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$vti" -o "$wan" -j ACCEPT
  iptables -C FORWARD -i "$wan" -o "$vti" -m state --state RELATED,ESTABLISHED -j ACCEPT 2>/dev/null || iptables -A FORWARD -i "$wan" -o "$vti" -m state --state RELATED,ESTABLISHED -j ACCEPT
  gum style --foreground 46 "Forwarding policy repaired for $vti <-> $wan"
}

fw_show_managed() {
  clear
  fw_init
  gum style --foreground 45 --bold "Boghche Managed Rules"
  if [ ! -s "$RULES_FILE" ]; then
    echo "No Boghche-managed firewall policies yet."
    return
  fi
  jq -r '"- [\(.action)] \(.source) -> \(.destination) \(.protocol)/\(.port)  \(.time)"' "$RULES_FILE" 2>/dev/null || cat "$RULES_FILE"
}

firewall_menu() {
  while true; do
    clear
    gum style --foreground 220 --bold "Access Control Center"
    choice=$(gum choose \
      "Allow access" \
      "Restrict access" \
      "Enable NAT for subnet" \
      "Repair tunnel forwarding" \
      "Show Boghche-managed rules" \
      "Back")

    case "$choice" in
      "Allow access") fw_allow_access; pause ;;
      "Restrict access") fw_restrict_access; pause ;;
      "Enable NAT for subnet") fw_enable_nat; pause ;;
      "Repair tunnel forwarding") fw_repair_forwarding; pause ;;
      "Show Boghche-managed rules") fw_show_managed; pause ;;
      "Back") return ;;
    esac
  done
}
