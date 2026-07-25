#!/usr/bin/env bash

set -euo pipefail

copy_overlay() {
    local file="$1"
    shift

    mkdir -p "$(dirname "$file")"

    install "$@" "/tmp/overlay${file}" "$file"
}

echo "Installing packages..."

apt-get update

apt-get install --no-install-recommends -y \
    tcpdump \
    avahi-daemon \
    avahi-utils \
    dnsmasq \
    dhcpcd5 \
    iw \
    wireless-tools

echo "Installing configuration files..."

copy_overlay /etc/avahi/services/nanopizero2.service -o root -g root -m 644

copy_overlay /etc/dnsmasq.d/eth0.conf -o root -g root -m 644

copy_overlay /etc/sudoers.d/pi-scanning -o root -g root -m 440
visudo -c -f /etc/sudoers.d/pi-scanning

echo "Configuring eth0 fallback..."

if ! grep -q "profile static_eth0" /etc/dhcpcd.conf; then
    cat >> /etc/dhcpcd.conf <<'EOF'

# Static fallback profile for eth0
profile static_eth0
static ip_address=192.168.5.1/24

# eth0: try DHCP first, fall back to static if no lease obtained
interface eth0
fallback static_eth0
EOF
fi

echo "Configuring services..."

systemctl enable avahi-daemon
systemctl enable dnsmasq

systemctl disable NetworkManager || true

echo "Cleaning up..."

apt-get autoremove -y
apt-get clean
rm -rf /var/lib/apt/lists/*
rm -rf /var/cache/apt/*

echo "Done."
