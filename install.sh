#!/bin/bash
set -euo pipefail

REPO="https://raw.githubusercontent.com/sepehr-ad/boghche-gateway/main"

require_root() {
  if [ "${EUID}" -ne 0 ]; then
    echo "Please run as root"
    echo "Usage: sudo bash install.sh"
    exit 1
  fi
}

check_os() {
  source /etc/os-release

  if [[ "$ID" != "ubuntu" && "$ID" != "debian" ]]; then
    echo "Unsupported OS: $ID"
    exit 1
  fi
}

detect_arch() {
  ARCH=$(uname -m)

  case "$ARCH" in
    x86_64)
      GUM_ARCH="x86_64"
      ;;
    aarch64|arm64)
      GUM_ARCH="arm64"
      ;;
    *)
      echo "Unsupported architecture: $ARCH"
      exit 1
      ;;
  esac
}

install_packages() {
  export DEBIAN_FRONTEND=noninteractive

  apt update

  apt install -y \
    curl \
    jq \
    iproute2 \
    iptables \
    strongswan \
    strongswan-pki \
    libcharon-extra-plugins \
    ca-certificates \
    tar \
    gzip
}

install_gum() {
  if command -v gum >/dev/null 2>&1; then
    return
  fi

  echo "[+] Installing gum..."

  TMP_DIR=$(mktemp -d)
  VERSION="0.14.0"

  curl -fsSL \
    "https://github.com/charmbracelet/gum/releases/download/v${VERSION}/gum_${VERSION}_Linux_${GUM_ARCH}.tar.gz" \
    -o ${TMP_DIR}/gum.tar.gz

  tar -xzf ${TMP_DIR}/gum.tar.gz -C ${TMP_DIR}

  install \
    ${TMP_DIR}/gum_${VERSION}_Linux_${GUM_ARCH}/gum \
    /usr/local/bin/gum

  rm -rf ${TMP_DIR}
}

install_files() {
  mkdir -p \
    /usr/local/lib/boghche \
    /etc/boghche \
    /var/log/boghche

  curl -fsSL "$REPO/lib/engine.sh" -o /usr/local/lib/boghche/engine.sh
  curl -fsSL "$REPO/lib/utils.sh" -o /usr/local/lib/boghche/utils.sh
  curl -fsSL "$REPO/lib/ipsec.sh" -o /usr/local/lib/boghche/ipsec.sh || true
  curl -fsSL "$REPO/lib/vtiup.sh" -o /usr/local/lib/boghche/vtiup.sh || true
  curl -fsSL "$REPO/bin/boghche" -o /usr/local/bin/boghche
  curl -fsSL "$REPO/systemd/boghche.service" -o /etc/systemd/system/boghche.service

  chmod +x /usr/local/lib/boghche/*.sh || true
  chmod +x /usr/local/bin/boghche
}

configure_systemd() {
  systemctl daemon-reload
  systemctl enable boghche.service
}

validate_install() {
  command -v gum >/dev/null
  command -v jq >/dev/null
  command -v ip >/dev/null
  command -v ipsec >/dev/null

  echo "[✓] Validation successful"
}

main() {
  echo "[+] Installing Boghche Gateway..."

  require_root
  check_os
  detect_arch
  install_packages
  install_gum
  install_files
  configure_systemd
  validate_install

  echo "[✓] Installation complete"
  echo "Run: sudo boghche"
}

main
