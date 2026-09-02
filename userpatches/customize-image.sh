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

# Answer wireshark-common's debconf prompt non-interactively so dumpcap gets
# set up for non-root capture (adds the `wireshark` group + capabilities on
# /usr/bin/dumpcap), same as `dpkg-reconfigure wireshark-common` would do.
echo "wireshark-common wireshark-common/install-setuid boolean true" | debconf-set-selections

apt-get install --no-install-recommends -y \
    tcpdump \
    wireshark-common \
    avahi-daemon \
    avahi-utils \
    iw \
    wireless-tools

echo "Validating configuration..."

visudo -c -f /tmp/overlay/etc/sudoers.d/pi-nopasswd-wifi

echo "Installing configuration files..."

copy_overlay /etc/avahi/services/nanopizero2.service \
    -o root -g root -m 0644

copy_overlay /etc/sudoers.d/pi-nopasswd-wifi \
    -o root -g root -m 0440

copy_overlay /usr/local/sbin/usb-gadget \
    -o root -g root -m 0755

copy_overlay /etc/systemd/system/usb-gadget.service \
    -o root -g root -m 0644

# Mainline dwc3 (OTG) may register the UDC after sysinit or only when a host is attached; udev
# starts this unit on every UDC add so the NCM gadget binds whenever the controller appears.
copy_overlay /etc/systemd/system/usb-gadget-rebind.service \
    -o root -g root -m 0644

copy_overlay /etc/udev/rules.d/90-usb-gadget-udc.rules \
    -o root -g root -m 0644

copy_overlay /etc/systemd/network/20-usb0.network \
    -o root -g root -m 0644

copy_overlay /etc/systemd/network/10-ethernet.network \
    -o root -g root -m 0644

# WLAN Commander additions: see the header comments in each file for why.
copy_overlay /usr/local/sbin/wc-hostname \
    -o root -g root -m 0755
copy_overlay /etc/systemd/system/wc-hostname.service \
    -o root -g root -m 0644


echo "Configuring services..."

systemctl enable avahi-daemon.service
systemctl enable avahi-daemon.socket

systemctl enable usb-gadget.service

# Runs before avahi so the first mDNS advertisement already carries the unique,
# WC-discoverable name rather than the shared default.
systemctl enable wc-hostname.service
systemctl enable systemd-networkd.service

# Prevent other network managers from configuring interfaces.
systemctl disable NetworkManager.service 2>/dev/null || true
systemctl disable networking.service 2>/dev/null || true

echo "Configuring default accounts..."

if ! id -u pi &>/dev/null; then
    useradd -m -s /bin/bash -G sudo pi
fi
echo "pi:pi" | chpasswd

# Let pi run dumpcap (Airtool 2 / Airtool Pi) without sudo.
usermod -aG wireshark pi

# Optional, per builder: a public key for the pi account. The path is gitignored so the public
# fork never carries one; without it the only login is the published password, which is fine
# for the field but makes post-flash verification (and every reflash) a password dance.
if [[ -f /tmp/overlay/home/pi/.ssh/authorized_keys ]]; then
    echo "Installing authorized_keys for pi..."
    install -D -o pi -g pi -m 0700 -d /home/pi/.ssh
    install -o pi -g pi -m 0600 /tmp/overlay/home/pi/.ssh/authorized_keys /home/pi/.ssh/authorized_keys
fi

# Root login is locked by default; an administrator can re-enable it by
# setting a new password for root (e.g. `sudo passwd root`).
usermod -L root

# Accounts are already provisioned above, so skip Armbian's interactive
# first-login wizard (console/SSH prompt for root password + new user).
rm -f /root/.not_logged_in_yet

echo "Cleaning up..."

apt-get autoremove -y
apt-get clean

rm -rf /var/lib/apt/lists/*
rm -rf /var/cache/apt/*

echo "Customization complete."
