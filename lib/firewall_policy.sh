#!/bin/bash

# Shared validation and deterministic rule-plan generation for Boghche.
# This file intentionally does not change any runtime firewall state.

boghche_valid_ipv4_cidr() {
  local value="$1" address prefix octet
  local -a octets

  [ "$value" = "any" ] && return 0
  address="${value%%/*}"
  if [[ "$value" == */* ]]; then
    prefix="${value##*/}"
  else
    prefix="32"
  fi

  [[ "$address" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]] || return 1
  [[ "$prefix" =~ ^[0-9]+$ ]] || return 1
  [ "$prefix" -ge 0 ] && [ "$prefix" -le 32 ] || return 1

  IFS='.' read -r -a octets <<<"$address"
  [ "${#octets[@]}" -eq 4 ] || return 1
  for octet in "${octets[@]}"; do
    [[ "$octet" =~ ^[0-9]+$ ]] || return 1
    [ "$octet" -ge 0 ] && [ "$octet" -le 255 ] || return 1
  done
}

boghche_effective_nat_sources() {
  local config="$1"

  jq -r '
    ((if has("nat_sources") then .nat_sources else
      ["192.168.0.0/16","172.16.0.0/16","172.18.0.0/16","10.20.30.2/32"] +
      (.lans // []) + (.route_subnets // []) end) +
     (if (.vti_remote // "") == "" then []
      else [((.vti_remote | split("/")[0]) + "/32")] end)) |
    unique[]
  ' "$config"
}

boghche_valid_port() {
  local value="$1" start end

  [ "$value" = "any" ] && return 0
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    [ "$value" -ge 1 ] && [ "$value" -le 65535 ]
    return
  fi
  if [[ "$value" =~ ^([0-9]+):([0-9]+)$ ]]; then
    start="${BASH_REMATCH[1]}"
    end="${BASH_REMATCH[2]}"
    [ "$start" -ge 1 ] && [ "$end" -le 65535 ] && [ "$start" -le "$end" ]
    return
  fi
  return 1
}

boghche_firewall_validate_config() {
  local config="$1" index source destination protocol port action

  jq -e '
    (.firewall_policies // []) | type == "array" and all(.[]
      ; type == "object" and
        (.source | type == "string") and
        (.destination | type == "string") and
        ((.protocol // "any") | type == "string") and
        ((.port // "any") | type == "string") and
        (.action | type == "string") and
        ((.comment // "") | type == "string")
    )
  ' "$config" >/dev/null || {
    echo "firewall_policies must be an array of policy objects with string fields"
    return 1
  }

  while IFS=$'\t' read -r index source destination protocol port action; do
    boghche_valid_ipv4_cidr "$source" || {
      echo "Invalid firewall source in policy ${index}: ${source}"
      return 1
    }
    boghche_valid_ipv4_cidr "$destination" || {
      echo "Invalid firewall destination in policy ${index}: ${destination}"
      return 1
    }
    case "$protocol" in
      any|tcp|udp|icmp) ;;
      *) echo "Invalid firewall protocol in policy ${index}: ${protocol}"; return 1 ;;
    esac
    boghche_valid_port "$port" || {
      echo "Invalid firewall port in policy ${index}: ${port}"
      return 1
    }
    if [ "$protocol" != "tcp" ] && [ "$protocol" != "udp" ] && [ "$port" != "any" ]; then
      echo "Policy ${index}: ports are only valid with tcp or udp"
      return 1
    fi
    case "$action" in
      allow|block) ;;
      *) echo "Invalid firewall action in policy ${index}: ${action}"; return 1 ;;
    esac
  done < <(
    jq -r '(.firewall_policies // []) | to_entries[] |
      [(.key + 1), (.value.source // ""), (.value.destination // ""),
       (.value.protocol // "any"), (.value.port // "any"),
       (.value.action // "")] | @tsv' "$config"
  )
}

boghche_firewall_plan() {
  local config="$1"

  # Explicit policies always come first and retain their config.json order.
  jq -r '(.firewall_policies // []) | to_entries[] |
    ["policy", (.key + 1), (.value.source // "any"),
     (.value.destination // "any"), (.value.protocol // "any"),
     (.value.port // "any"), (.value.action // "block"),
     (.value.comment // "")] | @tsv' "$config"

  # Any source represented in the policy table becomes default-deny after its
  # ordered explicit policies. Sources absent from the table keep the legacy
  # pass-through behavior for a non-breaking upgrade.
  jq -r '(reduce ((.firewall_policies // [])[] | (.source // "any")) as $source
      ([]; if index($source) then . else . + [$source] end))[] |
    ["source-default", 0, ., "any", "any", "any", "block", "implicit default"] |
    @tsv' "$config"

  printf 'unmanaged-default\t0\tany\tany\tany\tany\tallow\tlegacy-compatible default\n'
}
