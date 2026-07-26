# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This repo builds a custom Armbian image for the FriendlyElec NanoPi Zero2 (Rockchip RK35xx), configured as a Wi-Fi scanning/sensor device ("Intuitibits NanoPi Zero2 sensor image"). It does not contain a full Armbian checkout — it's a thin wrapper (`build.sh`) plus a set of `userpatches/` that get copied into a freshly cloned Armbian `build` tree at build time.

There is no traditional source code, package manifest, or test suite here. "Building" means invoking the upstream Armbian build system with this repo's patches layered on top.

## Build

```bash
./build.sh
```

This script (idempotent, safe to re-run):
1. Clones `https://github.com/armbian/build.git` into `./build/` if not already present (pinned to tag in `ARMBIAN_TAG`, currently `v26.5.1`).
2. Fetches tags and force-checks-out that tag in the `build/` tree (discards any local changes there).
3. `rsync --delete`s `userpatches/` into `build/userpatches/` — this repo's `userpatches/` is the single source of truth; anything not present here is removed from the Armbian tree's copy.
4. Deletes previous `.img*` artifacts in `build/output/images/`.
5. Runs Armbian's `./compile.sh` with fixed parameters: `BOARD=nanopi-zero2 BRANCH=vendor RELEASE=trixie BUILD_MINIMAL=yes BUILD_DESKTOP=no KERNEL_CONFIGURE=no ENABLE_EXTENSIONS=iwlwifi-backport`.
6. Renames the resulting image/checksum/build-log to `intuitibits-nanopi-zero2-v<IMAGE_VERSION>.*` (version set at the top of `build.sh`).

The actual Armbian build system lives in `build/` (gitignored) and is not part of this repo — do not edit files under `build/` expecting changes to persist; edit `userpatches/` instead and re-run `build.sh` to have them synced in.

Bump `IMAGE_VERSION` in `build.sh` when cutting a new image; it flows into both the output filename and the avahi service's advertised `ver=` TXT record (`userpatches/overlay/etc/avahi/services/nanopizero2.service`) — keep these in sync.

There's no lint/test command; validation happens by running a full build (which takes a long time and compiles a kernel — Armbian's build system runs natively on a supported Ubuntu/Debian host or VM; Docker is only a fallback on unsupported host OSes) or by reasoning about the shell scripts directly.

## Structure of `userpatches/`

Armbian's build system looks for specific, well-known files/directories under `userpatches/` and calls them at specific build hook points. The pieces here:

- **`customize-image.sh`** — Armbian's standard customization hook, run inside the target rootfs chroot near the end of the image build. Installs packages (`tcpdump`, `avahi-daemon`, `avahi-utils`, `iw`, `wireless-tools`), validates and installs the files from `overlay/` into the rootfs at their real paths, and enables/disables systemd units. It intentionally disables `NetworkManager`/`networking.service` in favor of `systemd-networkd` (see `usb-gadget` below, which depends on `systemd-networkd` for the `usb0` interface).
- **`overlay/`** — mirrors the target rootfs layout (e.g. `overlay/etc/foo` installs as `/etc/foo`). `customize-image.sh`'s `copy_overlay()` helper reads from `/tmp/overlay/<path>` (where Armbian stages this directory during the chroot step) and installs to `<path>` with explicit owner/group/mode. When adding a new overlay file, you must also add a corresponding `copy_overlay` call in `customize-image.sh` — files aren't installed automatically just by existing in `overlay/`.
- **`extensions/iwlwifi-backport.sh`** — an Armbian build extension (hooks named `extension_prepare_config__*`, `custom_kernel_config__*`, `post_install_kernel_debs__*` are auto-discovered by Armbian's extension system) that compiles Intel `backport-iwlwifi` in-chroot post-build to add BE200 Wi-Fi 6E support, since the vendor kernel doesn't ship it. Enabled via `ENABLE_EXTENSIONS=iwlwifi-backport` in `build.sh`. Key things to know if touching this file:
  - It forces `CFG80211`/`MAC80211` to build as modules (`opts_m`) because the vendor defconfig ships them built-in, which would otherwise conflict with backport-iwlwifi's own modules at modpost time ("exported twice").
  - It detects at build time (rather than assuming from kernel version) whether the target kernel uses `del_timer_sync()` or `timer_delete_sync()` (renamed in v6.2) and patches backport-iwlwifi's source accordingly, since vendor kernels backport APIs selectively.
  - It works around a `depmod` quirk during `make install`: backport's install rule invokes the *build host's* `depmod` by absolute path, which would resolve to the wrong kernel version inside the chroot, so the script temporarily stubs out `depmod` on disk during `make install` and runs the real one manually afterward with the correct `TARGET_KERNEL_VERSION`.
- **`linux-rk35xx-vendor.config`** — a kernel defconfig fragment (`CONFIG_*` overrides) for the `rk35xx`/`vendor` kernel branch, merged in by Armbian's config system. Notable settings: `CFG80211=m`/`MAC80211=m` (required for iwlwifi-backport, see above), plus a broad set of enabled networking/netfilter/USB-gadget/wireless driver options.

## Device-specific behavior baked into the image

- **USB gadget (NCM)**: `overlay/usr/local/sbin/usb-gadget` configures a USB Ethernet (NCM) gadget via configfs on boot (`usb-gadget.service`, a oneshot unit run very early via `sysinit.target`, before normal network setup). The resulting `usb0` interface gets a static address and DHCP server config from `overlay/etc/systemd/network/20-usb0.network` (`192.168.7.1/24`, DHCP pool `.10`-`.29`) — this is how a host machine gets network access to the device over USB.
- **Wi-Fi scanning access**: `overlay/etc/sudoers.d/pi-scanning` grants the `pi` user passwordless sudo for exactly `iw`, `ip`, and `tcpdump` — the minimum needed for Wi-Fi scanning/packet capture tooling without full root.
- **Discovery**: `overlay/etc/avahi/services/nanopizero2.service` advertises `_http._tcp` (port 31415, with `model`/`ver` TXT records) and `_ssh._tcp` (port 22, `id=wlanpi`) over mDNS for zero-config discovery on the network.
- **Networking manager choice**: `systemd-networkd` is authoritative for interface configuration on this image (NetworkManager and ifupdown are explicitly disabled in `customize-image.sh`); any new network interface config should be added as a `systemd/network/*.network` unit, following the pattern in `20-usb0.network`.
