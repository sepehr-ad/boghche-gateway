#!/bin/bash

REPO="https://raw.githubusercontent.co/sepehr-ad/boghche-gateway/main"

echo "[+] Installing Baghcheh Gateway..."

apt update
apt install -y jq curl

mkdir -p /usr/local/lib/baghcheh
mkdir -p /etc/baghcheh

curl -sL $REPO/lib/vti-engine.sh -o /usr/local/lib/baghcheh/vti-engine.sh
curl -sL $REPO/bin/baghcheh -o /usr/local/bin/baghcheh
curl -sL $REPO/systemd/baghcheh.service -o /etc/systemd/system/baghcheh.service

chmod +x /usr/local/lib/baghcheh/vti-engine.sh
chmod +x /usr/local/bin/baghcheh

systemctl daemon-reload
systemctl enable baghcheh

echo "[✓] Installation Complete."
echo "Run: sudo baghcheh init"
