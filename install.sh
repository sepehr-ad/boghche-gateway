#!/bin/bash

REPO="https://raw.githubusercontent.com/sepehr-ad/boghche-gateway/main"

echo "[+] Installing Boghche Gateway..."

apt update
apt install -y jq curl iproute2 iptables

# نصب gum (نسخه لینوکسی amd64؛ اگر معماری فرق داره، اصلاح کن)
if ! command -v gum >/dev/null 2>&1; then
  echo "[+] Installing gum..."
  curl -sL https://github.com/charmbracelet/gum/releases/latest/download/gum_0.14.0_Linux_x86_64.tar.gz \
  | tar -xz && mv gum /usr/local/bin/
fi

mkdir -p /usr/local/lib/boghche
mkdir -p /etc/boghche
mkdir -p /var/log/boghche

curl -sL $REPO/lib/engine.sh -o /usr/local/lib/boghche/engine.sh
curl -sL $REPO/lib/utils.sh  -o /usr/local/lib/boghche/utils.sh
curl -sL $REPO/bin/boghche   -o /usr/local/bin/boghche
curl -sL $REPO/systemd/boghche.service -o /etc/systemd/system/boghche.service

chmod +x /usr/local/lib/boghche/*.sh
chmod +x /usr/local/bin/boghche

systemctl daemon-reload
systemctl enable boghche

echo "[✓] Installation Complete."
echo "Run: sudo boghche"
