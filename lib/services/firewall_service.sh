#!/bin/bash
set -euo pipefail

CONFIG="/etc/boghche/config.json"
POLICY_HELPER="/usr/local/lib/boghche/firewall_policy.sh"
DEFAULT_NAT_SOURCES='["192.168.0.0/16","172.16.0.0/16","172.18.0.0/16","10.20.30.2/32"]'

if [ -f "$POLICY_HELPER" ]; then
  source "$POLICY_HELPER"
else
  echo "Missing Boghche firewall policy helper: $POLICY_HELPER"
  return 1
fi

fw_ask() {
  local label="$1"
  local default="${2:-}"
  if [ -n "$default" ]; then
    gum input --value "$default" --placeholder "$label"
  else
    gum input --placeholder "$label"
  fi
}

fw_require_config() {
  [ -f "$CONFIG" ] || {
    gum style --foreground 196 "No config found. Run Configure / Apply Tunnel first."
    return 1
  }
}

fw_commit_tmp() {
  local tmp="$1"
  chmod 600 "$tmp"
  mv "$tmp" "$CONFIG"
}

fw_show_policies() {
  local count
  clear
  fw_require_config || return
  gum style --foreground 45 --bold "Firewall Policy Table"
  count=$(jq -r '(.firewall_policies // []) | length' "$CONFIG")

  if [ "$count" -eq 0 ]; then
    echo "No policies. VTI -> WAN traffic keeps the compatibility default: allow."
  else
    printf '%-4s %-19s %-19s %-8s %-9s %-7s %s\n' \
      "#" "SOURCE" "DESTINATION" "PROTO" "PORT" "ACTION" "COMMENT"
    jq -r '(.firewall_policies // []) | to_entries[] |
      [(.key + 1), .value.source, .value.destination, .value.protocol,
       .value.port, .value.action, (.value.comment // "-")] | @tsv' "$CONFIG" |
      while IFS=$'\t' read -r number source destination protocol port action comment; do
        printf '%-4s %-19s %-19s %-8s %-9s %-7s %s\n' \
          "$number" "$source" "$destination" "$protocol" "$port" "$action" "$comment"
      done
    echo
    echo "First match wins. Unmatched traffic from every Source listed above is blocked."
    echo "Sources absent from this table keep the compatibility default: allow."
  fi
}

fw_add_policy() {
  local default_source source destination protocol port action comment tmp
  clear
  fw_require_config || return
  gum style --foreground 46 --bold "Add Firewall Policy"

  default_source=$(jq -r '.vti_remote // empty' "$CONFIG")
  if [ -n "$default_source" ]; then
    default_source="${default_source%%/*}/32"
  else
    default_source="192.168.0.0/16"
  fi
  source=$(fw_ask "Source IP/subnet or any" "$default_source")
  destination=$(fw_ask "Destination IP/subnet or any" "any")
  protocol=$(gum choose "any" "tcp" "udp" "icmp")
  if [ "$protocol" = "tcp" ] || [ "$protocol" = "udp" ]; then
    port=$(fw_ask "Destination port, range 80:90, or any" "any")
  else
    port="any"
  fi
  action=$(gum choose "allow" "block")
  comment=$(fw_ask "Short comment" "managed by Boghche")
  comment=$(printf '%s' "$comment" | tr -d '\t\r\n' | cut -c1-120)

  boghche_valid_ipv4_cidr "$source" || {
    gum style --foreground 196 "Invalid source: $source"
    return
  }
  boghche_valid_ipv4_cidr "$destination" || {
    gum style --foreground 196 "Invalid destination: $destination"
    return
  }
  boghche_valid_port "$port" || {
    gum style --foreground 196 "Invalid port: $port"
    return
  }

  tmp=$(mktemp "${CONFIG}.tmp.XXXXXX")
  jq \
    --arg source "$source" --arg destination "$destination" \
    --arg protocol "$protocol" --arg port "$port" \
    --arg action "$action" --arg comment "$comment" \
    '.firewall_policies = ((.firewall_policies // []) + [{
      source:$source,destination:$destination,protocol:$protocol,
      port:$port,action:$action,comment:$comment
    }])' "$CONFIG" > "$tmp"
  fw_commit_tmp "$tmp"
  gum style --foreground 46 "Policy saved at the end of the table. Apply saved tables when ready."
}

fw_delete_policy() {
  local count number index tmp
  fw_require_config || return
  count=$(jq -r '(.firewall_policies // []) | length' "$CONFIG")
  [ "$count" -gt 0 ] || { gum style --foreground 220 "No policy to delete."; return; }
  fw_show_policies
  number=$(fw_ask "Policy number to delete")
  [[ "$number" =~ ^[0-9]+$ ]] && [ "$number" -ge 1 ] && [ "$number" -le "$count" ] || {
    gum style --foreground 196 "Invalid policy number."
    return
  }
  index=$((number - 1))
  tmp=$(mktemp "${CONFIG}.tmp.XXXXXX")
  jq --argjson index "$index" 'del(.firewall_policies[$index])' "$CONFIG" > "$tmp"
  fw_commit_tmp "$tmp"
  gum style --foreground 46 "Policy ${number} deleted. Apply saved tables when ready."
}

fw_move_policy() {
  local count from to from_index to_index tmp
  fw_require_config || return
  count=$(jq -r '(.firewall_policies // []) | length' "$CONFIG")
  [ "$count" -gt 1 ] || { gum style --foreground 220 "At least two policies are required to reorder."; return; }
  fw_show_policies
  from=$(fw_ask "Policy number to move")
  to=$(fw_ask "New position (1-${count})")
  [[ "$from" =~ ^[0-9]+$ && "$to" =~ ^[0-9]+$ ]] && \
    [ "$from" -ge 1 ] && [ "$from" -le "$count" ] && \
    [ "$to" -ge 1 ] && [ "$to" -le "$count" ] || {
      gum style --foreground 196 "Invalid policy position."
      return
    }
  from_index=$((from - 1))
  to_index=$((to - 1))
  tmp=$(mktemp "${CONFIG}.tmp.XXXXXX")
  jq --argjson from "$from_index" --argjson to "$to_index" '
    (.firewall_policies // []) as $rules |
    ($rules[$from]) as $item |
    ($rules | del(.[$from])) as $remaining |
    .firewall_policies = ($remaining[0:$to] + [$item] + $remaining[$to:])
  ' "$CONFIG" > "$tmp"
  fw_commit_tmp "$tmp"
  gum style --foreground 46 "Policy moved to position ${to}. Apply saved tables when ready."
}

fw_show_nat() {
  local enabled remote
  clear
  fw_require_config || return
  gum style --foreground 45 --bold "NAT Source Table"
  enabled=$(jq -r '.nat // false' "$CONFIG")
  echo "NAT enabled: $enabled"
  echo
  printf '%-4s %-19s %s\n' "#" "SOURCE" "TYPE"
  jq -r --argjson defaults "$DEFAULT_NAT_SOURCES" '
    (if has("nat_sources") then .nat_sources else $defaults end) |
    to_entries[] | [(.key + 1), .value, "configured"] | @tsv
  ' "$CONFIG" | while IFS=$'\t' read -r number source type; do
    printf '%-4s %-19s %s\n' "$number" "$source" "$type"
  done
  remote=$(jq -r '.vti_remote // empty' "$CONFIG")
  if [ -n "$remote" ]; then
    printf '%-4s %-19s %s\n' "-" "${remote%%/*}/32" "automatic VTI peer"
  fi
}

fw_add_nat_source() {
  local source tmp
  fw_require_config || return
  source=$(fw_ask "NAT source IP/subnet" "192.168.0.0/16")
  if [ "$source" = "any" ] || ! boghche_valid_ipv4_cidr "$source"; then
    gum style --foreground 196 "Invalid NAT source: $source"
    return
  fi
  tmp=$(mktemp "${CONFIG}.tmp.XXXXXX")
  jq --arg source "$source" --argjson defaults "$DEFAULT_NAT_SOURCES" '
    .nat_sources = (((if has("nat_sources") then .nat_sources else $defaults end) + [$source]) | unique)
  ' "$CONFIG" > "$tmp"
  fw_commit_tmp "$tmp"
  gum style --foreground 46 "NAT source saved. Apply saved tables when ready."
}

fw_delete_nat_source() {
  local count number index tmp
  fw_require_config || return
  count=$(jq -r --argjson defaults "$DEFAULT_NAT_SOURCES" '
    (if has("nat_sources") then .nat_sources else $defaults end) | length
  ' "$CONFIG")
  [ "$count" -gt 0 ] || { gum style --foreground 220 "No configured NAT source to delete."; return; }
  fw_show_nat
  number=$(fw_ask "Configured NAT source number to delete")
  [[ "$number" =~ ^[0-9]+$ ]] && [ "$number" -ge 1 ] && [ "$number" -le "$count" ] || {
    gum style --foreground 196 "Invalid NAT source number."
    return
  }
  index=$((number - 1))
  tmp=$(mktemp "${CONFIG}.tmp.XXXXXX")
  jq --argjson index "$index" --argjson defaults "$DEFAULT_NAT_SOURCES" '
    .nat_sources = ((if has("nat_sources") then .nat_sources else $defaults end) | del(.[$index]))
  ' "$CONFIG" > "$tmp"
  fw_commit_tmp "$tmp"
  gum style --foreground 46 "NAT source deleted. The automatic VTI peer cannot be deleted here."
}

fw_set_nat_state() {
  local choice enabled tmp
  fw_require_config || return
  choice=$(gum choose "Enable NAT" "Disable NAT")
  [ "$choice" = "Enable NAT" ] && enabled=true || enabled=false
  tmp=$(mktemp "${CONFIG}.tmp.XXXXXX")
  jq --argjson enabled "$enabled" '.nat = $enabled' "$CONFIG" > "$tmp"
  fw_commit_tmp "$tmp"
  gum style --foreground 46 "NAT state saved as ${enabled}. Apply saved tables when ready."
}

fw_nat_menu() {
  local choice
  while true; do
    clear
    gum style --foreground 45 --bold "NAT Sources"
    choice=$(gum choose \
      "Show NAT table" \
      "Add NAT source" \
      "Delete NAT source" \
      "Enable / Disable NAT" \
      "Back")
    case "$choice" in
      "Show NAT table") fw_show_nat; pause ;;
      "Add NAT source") fw_add_nat_source; pause ;;
      "Delete NAT source") fw_delete_nat_source; pause ;;
      "Enable / Disable NAT") fw_set_nat_state; pause ;;
      "Back") return ;;
    esac
  done
}

fw_apply() {
  clear
  fw_require_config || return
  gum style --foreground 45 --bold "Apply NAT and Firewall Tables"
  if systemctl restart boghche; then
    gum style --foreground 46 "Saved NAT and firewall tables are active."
  else
    gum style --foreground 196 "Apply failed. Existing user chains and global policies were not flushed."
    journalctl -u boghche -n 30 --no-pager || true
    return 1
  fi
}

firewall_menu() {
  local choice
  while true; do
    clear
    gum style --foreground 220 --bold "NAT and Firewall Policies"
    choice=$(gum choose \
      "Show policy table" \
      "Add policy" \
      "Delete policy" \
      "Move policy" \
      "NAT sources" \
      "Apply saved tables" \
      "Back")

    case "$choice" in
      "Show policy table") fw_show_policies; pause ;;
      "Add policy") fw_add_policy; pause ;;
      "Delete policy") fw_delete_policy; pause ;;
      "Move policy") fw_move_policy; pause ;;
      "NAT sources") fw_nat_menu ;;
      "Apply saved tables") fw_apply; pause ;;
      "Back") return ;;
    esac
  done
}
