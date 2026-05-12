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
    strongswan \
    strongswan-starter \
    strongswan-libcharon \
    strongswan-pki \
    libcharon-extra-plugins \
    iproute2 \
    iptables \
    jq \
    curl \
    git \
    tcpdump \
    unbound \
    ufw \
    ca-certificates \
    tar \
    gzip
}

configure_kernel() {
  modprobe ip_vti || true
  modprobe xfrm_user || true

  cat >/etc/sysctl.d/99-boghche.conf <<EOF
net.ipv4.ip_forward=1
net.ipv4.conf.all.rp_filter=0
net.ipv4.conf.default.rp_filter=0
net.ipv4.conf.eth0.rp_filter=0
net.ipv4.conf.vti0.rp_filter=0
net.ipv4.conf.all.accept_redirects=0
net.ipv4.conf.default.accept_redirects=0
EOF

  sysctl --system >/dev/null 2>&1 || true
}

install_gum() {
  if command -v gum >/dev/null 2>&1; then
    echo "[✓] gum already installed"
    return
  fi

  echo "[+] Installing gum..."

  TMP_DIR=$(mktemp -d)
  VERSION="0.14.0"

  case "$GUM_ARCH" in
    x86_64)
      GUM_FILE="gum_${VERSION}_Linux_x86_64.tar.gz"
      ;;
    arm64)
      GUM_FILE="gum_${VERSION}_Linux_arm64.tar.gz"
      ;;
  esac

  URL="https://github.com/charmbracelet/gum/releases/download/v${VERSION}/${GUM_FILE}"

  echo "[+] Downloading ${GUM_FILE}"

  curl -fL "$URL" -o ${TMP_DIR}/gum.tar.gz

  tar -xzf ${TMP_DIR}/gum.tar.gz -C ${TMP_DIR}

  GUM_BIN=$(find ${TMP_DIR} -type f -name gum | head -n 1)

  if [ -z "$GUM_BIN" ]; then
    echo "gum binary not found"
    exit 1
  fi

  install "$GUM_BIN" /usr/local/bin/gum

  rm -rf ${TMP_DIR}

  echo "[✓] gum installed"
}

install_files() {
  mkdir -p \
    /usr/local/lib/boghche \
    /etc/boghche \
    /etc/unbound/unbound.conf.d \
    /var/log/boghche

  curl -fsSL "$REPO/lib/engine.sh" -o /usr/local/lib/boghche/engine.sh
  curl -fsSL "$REPO/lib/utils.sh" -o /usr/local/lib/boghche/utils.sh
  curl -fsSL "$REPO/lib/ipsec.sh" -o /usr/local/lib/boghche/ipsec.sh || true
  curl -fsSL "$REPO/bin/boghche" -o /usr/local/bin/boghche
  curl -fsSL "$REPO/systemd/boghche.service" -o /etc/systemd/system/boghche.service || true

  chmod +x /usr/local/lib/boghche/*.sh || true
  chmod +x /usr/local/bin/boghche
}

configure_systemd() {
  systemctl daemon-reload

  systemctl enable strongswan-starter || true
  systemctl enable unbound || true
  systemctl enable boghche.service || true
}

validate_install() {
  command -v gum >/dev/null
  command -v jq >/dev/null
  command -v ip >/dev/null
  command -v ipsec >/dev/null
  command -v unbound >/dev/null
  command -v tcpdump >/dev/null

  echo "[✓] Validation successful"
}

main() {
  echo "[+] Installing Boghche Gateway..."

  require_root
  check_os
  detect_arch
  install_packages
  configure_kernel
  install_gum
  install_files
  configure_systemd
  validate_install

  echo "[✓] Installation complete"
  echo "Recommended route-mode defaults:"
  echo "  mtu=1480"
  echo "  vti_addr=10.12.12.2/30"
  echo "  vti_remote=10.12.12.1"
  echo "Run: sudo boghche"
}

main
