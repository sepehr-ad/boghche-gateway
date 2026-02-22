#!/bin/bash

REPO="https://raw.githubusercontent.com/sepehr-ad/boghche-gateway/main"

echo "[+] Installing Boghche Gateway..."

apt update
apt install -y jq curl

mkdir -p /usr/local/lib/boghche
mkdir -p /etc/boghche

curl -sL $REPO/lib/vti-engine.sh -o /usr/local/lib/boghche/vti-engine.sh
curl -sL $REPO/bin/boghche -o /usr/local/bin/boghche
curl -sL $REPO/systemd/boghche.service -o /etc/systemd/system/boghche.service

chmod +x /usr/local/lib/boghche/vti-engine.sh
chmod +x /usr/local/bin/boghche

systemctl daemon-reload
systemctl enable boghche

echo "[✓] Installation Complete."
echo "Run: sudo boghche init"
