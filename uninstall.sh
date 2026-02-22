#!/bin/bash

systemctl stop baghcheh
systemctl disable baghcheh

rm -rf /usr/local/lib/baghcheh
rm -f /usr/local/bin/baghcheh
rm -f /etc/systemd/system/baghcheh.service
rm -rf /etc/baghcheh

systemctl daemon-reload

echo "Baghcheh Gateway Removed."
