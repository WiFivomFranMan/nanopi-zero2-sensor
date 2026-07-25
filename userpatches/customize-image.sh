#!/usr/bin/env bash

set -euo pipefail

export DEBIAN_FRONTEND=noninteractive

copy_overlay() {
    local file="$1"
    shift

    local source="/tmp/overlay${file}"

    [[ -f "$source" ]] || {
        echo "ERROR: Missing overlay file: $source" >&2
        exit 1
    }

    install -D "$@" "$source" "$file"
}

echo "Installing packages..."

apt-get update

apt-get install --no-install-recommends -y \
    tcpdump \
    avahi-daemon \
    avahi-utils \
    iw \
    wireless-tools

echo "Validating configuration..."

visudo -c -f /tmp/overlay/etc/sudoers.d/pi-scanning

echo "Installing configuration files..."

copy_overlay /etc/avahi/services/nanopizero2.service \
    -o root -g root -m 0644

copy_overlay /etc/sudoers.d/pi-scanning \
    -o root -g root -m 0440

copy_overlay /usr/local/sbin/usb-gadget \
    -o root -g root -m 0755

copy_overlay /etc/systemd/system/usb-gadget.service \
    -o root -g root -m 0644

copy_overlay /etc/systemd/network/20-usb0.network \
    -o root -g root -m 0644

echo "Configuring services..."

systemctl enable avahi-daemon.service
systemctl enable avahi-daemon.socket

systemctl enable usb-gadget.service
systemctl enable systemd-networkd.service

# Prevent other network managers from configuring interfaces.
systemctl disable NetworkManager.service 2>/dev/null || true
systemctl disable networking.service 2>/dev/null || true

echo "Cleaning up..."

apt-get autoremove -y
apt-get clean

rm -rf /var/lib/apt/lists/*
rm -rf /var/cache/apt/*

echo "Customization complete."
