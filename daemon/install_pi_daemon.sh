#!/usr/bin/env bash
# PiAuditor BLE Daemon Installation Script for Kali Linux ARM64 / Raspberry Pi

set -e

echo "[*] Installing PiAuditor BLE Daemon dependencies..."
apt-get update
apt-get install -y python3-dbus python3-gi bluez libbluetooth-dev wireless-tools network-manager

echo "[*] Configuring Bluetooth Service..."
# Enable experimental features for BlueZ GATT & LE Advertising
sed -i 's/^ExecStart=\/usr\/lib\/bluetooth\/bluetoothd$/ExecStart=\/usr\/lib\/bluetooth\/bluetoothd -E/' /lib/systemd/system/bluetooth.service || true
systemctl daemon-reload
systemctl restart bluetooth

echo "[*] Deploying daemon files to /home/khoa/wifi_auditor/..."
mkdir -p /home/khoa/wifi_auditor
cp ble_auditor_daemon.py /home/khoa/wifi_auditor/ble_auditor_daemon.py
chmod +x /home/khoa/wifi_auditor/ble_auditor_daemon.py

echo "[*] Installing systemd service..."
cp ble-auditor.service /etc/systemd/system/ble-auditor.service
systemctl daemon-reload
systemctl enable ble-auditor.service
systemctl restart ble-auditor.service

echo "[+] PiAuditor BLE Daemon successfully installed and running!"
systemctl status ble-auditor.service --no-pager
