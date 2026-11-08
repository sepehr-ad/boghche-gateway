#!/bin/bash
set -euo pipefail

_pause(){ echo; gum confirm "Return?" >/dev/null 2>&1 || true; }

maintenance_health() {
  clear
  gum style --foreground 45 --bold "Gateway Health Audit"
  local loaded vti mtu runtime_mtu mss forecast_rules wan nat_enabled
  local vti_remote remote_source nat_sources policy_count policy_sources
  echo "Tunnel service : $(systemctl is-active boghche 2>/dev/null || true)"
  echo "IPSec service  : $(systemctl is-active strongswan-starter 2>/dev/null || true)"
  echo "DNS service    : $(systemctl is-active unbound 2>/dev/null || true)"
  echo "IP forwarding  : $(sysctl -n net.ipv4.ip_forward 2>/dev/null || true)"
  echo "XFRM tmpl total: $(grep XfrmInTmplMismatch /proc/net/xfrm_stat 2>/dev/null | awk '{print $2}') (cumulative)"

  loaded=$(ipsec statusall 2>/dev/null | grep 'loaded plugins' || true)
  if grep -qw forecast <<<"$loaded"; then
    echo "forecast plugin: ERROR - loaded"
  else
    echo "forecast plugin: disabled"
  fi
  if grep -qw connmark <<<"$loaded"; then
    echo "connmark plugin: ERROR - loaded"
  else
    echo "connmark plugin: disabled"
  fi

  forecast_rules=0
  if command -v iptables-legacy >/dev/null 2>&1; then
    forecast_rules=$(iptables-legacy -t mangle -S PREROUTING 2>/dev/null |
      grep -cE -- '-p esp .* -j MARK| -j MARK .* -p esp' || true)
  fi
  echo "Legacy ESP MARK: $forecast_rules rule(s)"

  if [ -f /etc/boghche/config.json ]; then
    vti=$(jq -r '.vti_if // "vti0"' /etc/boghche/config.json 2>/dev/null || echo vti0)
    wan=$(jq -r '.wan_if // "eth0"' /etc/boghche/config.json 2>/dev/null || echo eth0)
    mtu=$(jq -r '.mtu // "1400"' /etc/boghche/config.json 2>/dev/null || echo 1400)
    runtime_mtu=$(cat /sys/class/net/"$vti"/mtu 2>/dev/null || echo n/a)
    mss=$(jq -r '.tcp_mss // empty' /etc/boghche/config.json 2>/dev/null || true)
    [ -n "$mss" ] || mss=$((mtu - 40))
    echo "VTI MTU config : $mtu"
    echo "VTI MTU runtime: $runtime_mtu"
    echo "TCP MSS        : $mss"
    echo "VTI tx errors  : $(cat /sys/class/net/"$vti"/statistics/tx_errors 2>/dev/null || echo n/a)"
    if ip rule show | grep -qE '^220:.*lookup 220'; then
      echo "Route table 220: WARNING - stale StrongSwan rule present"
    else
      echo "Route table 220: clean"
    fi
    if iptables -t mangle -C FORWARD -j BOGHCHE-MSS 2>/dev/null; then
      echo "MSS clamp      : active"
    else
      echo "MSS clamp      : MISSING"
    fi

    nat_enabled=$(jq -r '.nat // false' /etc/boghche/config.json 2>/dev/null || echo false)
    vti_remote=$(jq -r '.vti_remote // empty' /etc/boghche/config.json 2>/dev/null || true)
    remote_source=""
    [ -n "$vti_remote" ] && remote_source="${vti_remote%%/*}/32"
    nat_sources=$(jq -r --arg remote "$remote_source" '
      ((if has("nat_sources") then .nat_sources else
        ["192.168.0.0/16","172.16.0.0/16","172.18.0.0/16","10.20.30.2/32"] +
        (.lans // []) + (.route_subnets // []) end) +
       (if $remote == "" then [] else [$remote] end)) | unique | length
    ' /etc/boghche/config.json 2>/dev/null || echo 0)
    policy_count=$(jq -r '(.firewall_policies // []) | length' /etc/boghche/config.json 2>/dev/null || echo 0)
    policy_sources=$(jq -r '[(.firewall_policies // [])[].source] | unique | length' /etc/boghche/config.json 2>/dev/null || echo 0)

    echo "NAT config     : ${nat_enabled} (${nat_sources} effective source(s))"
    if [ "$nat_enabled" = "true" ] && iptables -t nat -C POSTROUTING -j BOGHCHE-POSTROUTING 2>/dev/null; then
      echo "NAT chain hook : active"
    elif [ "$nat_enabled" = "false" ]; then
      echo "NAT chain hook : disabled by config"
    else
      echo "NAT chain hook : MISSING"
    fi
    if [ "$nat_enabled" = "true" ] && [ -n "$remote_source" ]; then
      if iptables -t nat -C BOGHCHE-POSTROUTING -s "$remote_source" -o "$wan" -j MASQUERADE 2>/dev/null; then
        echo "VTI peer NAT   : active (${remote_source})"
      else
        echo "VTI peer NAT   : MISSING (${remote_source})"
      fi
    fi
    if iptables -C FORWARD -j BOGHCHE-FORWARD 2>/dev/null; then
      echo "Firewall hook  : active"
    else
      echo "Firewall hook  : MISSING"
    fi
    echo "Firewall table : ${policy_count} policy(s), ${policy_sources} source-default block(s)"
    echo "Policy behavior: first match; listed sources block by default; other sources allow"
  fi
}

maintenance_backup() {
  mkdir -p /var/backups/boghche
  file="/var/backups/boghche/boghche-$(date -u +%Y%m%d-%H%M%S).tar.gz"
  tar -czf "$file" /etc/boghche /etc/ipsec.conf /etc/ipsec.secrets /etc/unbound/unbound.conf.d/boghche.conf 2>/dev/null || true
  gum style --foreground 46 "Backup created: $file"
}

maintenance_cleanup() {
  rm -rf /var/lib/boghche/stats/current/* /var/lib/boghche/stats/state/* 2>/dev/null || true
  /usr/local/lib/boghche/metrics.sh prune || true
  gum style --foreground 46 "Telemetry cache cleaned"
}

maintenance_repair() {
  /usr/local/lib/boghche/unbound.sh || true
  systemctl restart unbound || true
  systemctl restart boghche || true
  gum style --foreground 46 "Core services repaired and restarted"
}

maintenance_menu() {
  while true; do
    clear
    gum style --foreground 141 --bold "Gateway Maintenance Center"
    choice=$(gum choose "Health audit" "Backup gateway" "Repair services" "Cleanup telemetry" "Back")
    case "$choice" in
      "Health audit") maintenance_health; _pause ;;
      "Backup gateway") maintenance_backup; _pause ;;
      "Repair services") maintenance_repair; _pause ;;
      "Cleanup telemetry") maintenance_cleanup; _pause ;;
      "Back") return ;;
    esac
  done
}
