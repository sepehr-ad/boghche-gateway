#!/bin/bash
set -euo pipefail

BOGHCHE_BACKUP_DIR="/var/backups/boghche/safety"
BOGHCHE_SSH_PORT="${BOGHCHE_SSH_PORT:-22}"

safety_init() {
  mkdir -p "$BOGHCHE_BACKUP_DIR"
}

safety_confirm() {
  local message="$1"
  gum confirm "$message" || return 1
}

safety_snapshot() {
  safety_init
  local ts
  ts=$(date -u +%Y%m%d-%H%M%S)
  iptables-save > "${BOGHCHE_BACKUP_DIR}/iptables-${ts}.save" 2>/dev/null || true
  iptables-legacy-save > "${BOGHCHE_BACKUP_DIR}/iptables-legacy-${ts}.save" 2>/dev/null || true
  nft list ruleset > "${BOGHCHE_BACKUP_DIR}/nft-${ts}.rules" 2>/dev/null || true
  ufw status numbered > "${BOGHCHE_BACKUP_DIR}/ufw-${ts}.txt" 2>/dev/null || true
}

safety_preserve_ssh() {
  if command -v ufw >/dev/null 2>&1; then
    ufw allow "${BOGHCHE_SSH_PORT}/tcp" >/dev/null 2>&1 || true
  fi

  iptables -C INPUT -p tcp --dport "$BOGHCHE_SSH_PORT" -j ACCEPT 2>/dev/null || \
    iptables -I INPUT 1 -p tcp --dport "$BOGHCHE_SSH_PORT" -j ACCEPT 2>/dev/null || true
}

safety_apply_gate() {
  local description="$1"
  gum style --foreground 220 --bold "Safety check"
  echo "$description"
  echo
  echo "Before applying, Boghche will:"
  echo "- preserve SSH on tcp/${BOGHCHE_SSH_PORT}"
  echo "- snapshot firewall state under ${BOGHCHE_BACKUP_DIR}"
  echo "- avoid changing default firewall policies"
  echo
  safety_confirm "Apply this network change?"
}

safe_network_change() {
  local description="$1"
  shift
  safety_apply_gate "$description" || return 1
  safety_snapshot
  safety_preserve_ssh
  "$@"
  safety_preserve_ssh
}
