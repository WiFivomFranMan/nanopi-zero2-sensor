# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

This repo builds a custom Armbian image for the FriendlyElec NanoPi Zero2 (Rockchip RK3528), configured as a Wi-Fi scanning/sensor device for Intuitibits' tools and for WLAN Commander. It does not contain a full Armbian checkout — it's a thin wrapper (`build.sh`) plus a set of `userpatches/` that get copied into a freshly cloned Armbian `build` tree at build time.

There is no traditional source code, package manifest, or test suite here. "Building" means invoking the upstream Armbian build system with this repo's patches layered on top.

**Two kernels are supported, selected by `WC_BRANCH`.** They are not interchangeable and the Armbian framework is pinned separately for each:

| `WC_BRANCH` | Kernel | Armbian pin | Extension | Why |
|---|---|---|---|---|
| `vendor` | Rockchip 6.1 BSP (`rk-6.1-rkr5.1`) | `v26.5.1` | `iwlwifi-backport` | The 1.0.x images. BE200 only works through Intel's out-of-tree backport driver compiled in the chroot. |
| `edge` | mainline `linux-7.2.y` | `v26.11.0-trunk.30` | `wifi7-mainline` | In-tree iwlwifi/iwlmld, mt7925, ath12k, rtw89. Stable branch. |
| `bleedingedge` (default) | mainline `v7.3-rc` tag | `v26.11.0-trunk.30` | `wifi7-mainline` | Same RK3528 support as 7.2 (the DTs are identical); newest Wi-Fi code. |

`current` (6.18 LTS) is refused: its iwlwifi accepts BE200 firmware up to core 99 only, and no such file exists any more.

**Moving between them is not a one-variable change — read `.claude/skills/mainline-kernel-upgrade/SKILL.md` first.** It records what was verified, what is still out-of-tree, and how to check an image before flashing.

## Build

```bash
./build.sh                                   # bleedingedge (7.3-rc), extension wifi7-mainline
WC_BRANCH=edge ./build.sh                    # 7.2.y
WC_BRANCH=vendor ./build.sh                  # the 6.1 vendor image, exactly as 1.0.x was built
WC_IGNORE_CACHE=yes ./build.sh               # first mainline build: bypass Armbian's artifact cache (armbian/build#9508)
```

This script (idempotent, safe to re-run):
1. Clones `https://github.com/armbian/build.git` into `./build/` if not already present.
2. Fetches tags and `main`, then force-checks-out the **commit SHA** pinned for the branch (the tag is documentation: Armbian prunes trunk tags). Any local change in `build/` is discarded.
3. `rsync --delete`s `userpatches/` into `build/userpatches/` — this repo's `userpatches/` is the single source of truth.
4. **Archives** previous `.img*` files into `build/output/images/archive/<timestamp>/`. It used to delete them; that destroyed the only copy of a working image once.
5. Runs Armbian's `./compile.sh` with `BOARD=nanopi-zero2 BRANCH=<branch> RELEASE=trixie BUILD_MINIMAL=yes BUILD_DESKTOP=no KERNEL_CONFIGURE=no ENABLE_EXTENSIONS=<per branch> INCLUDE_HOME_DIR=yes ARTIFACT_IGNORE_CACHE=<WC_IGNORE_CACHE>`. `INCLUDE_HOME_DIR=yes` is required: Armbian excludes `/home/*` from the final image otherwise, which drops `/home/pi` while the account survives in `/etc/passwd` — the symptom is sshd refusing login with "Could not chdir to home directory".
6. Renames the image to `intuitibits-nanopi-zero2-v<IMAGE_VERSION>-<branch>.*`, writes a `.build-info` provenance file (fork commit, Armbian commit, branch, extensions), then `xz`-compresses and `sha256sum`s it. Compression isn't optional: the raw `.img` is several GB, over GitHub Releases' 2 GB per-asset limit.

The actual Armbian build system lives in `build/` (gitignored) and is not part of this repo — do not edit files under `build/` expecting changes to persist; edit `userpatches/` instead and re-run `build.sh`.

Bump `IMAGE_VERSION` in `build.sh` when cutting a new image; it flows into the output filename, and the avahi `ver=` TXT record in `userpatches/overlay/etc/avahi/services/nanopizero2.service` must be kept in step by hand.

There's no lint/test command for the image; validation is a full build (~1 h warm, 1.5–2 h with the cache bypass; it compiles a kernel) on a supported Ubuntu/Debian host, followed by `.claude/skills/mainline-kernel-upgrade/checklists/offline-image-check.md`. The shell files can be checked locally with `bash -n` and `shellcheck`, and the `wifi7-mainline` verify hooks have a fake-tree unit test described in the skill.

## Structure of `userpatches/`

Armbian's build system looks for specific, well-known files/directories under `userpatches/` and calls them at specific build hook points. The pieces here:

- **`customize-image.sh`** — Armbian's standard customization hook, run inside the target rootfs chroot near the end of the image build. Installs packages (`tcpdump`, `wireshark-common`, `avahi-daemon`, `avahi-utils`, `iw`, `wireless-tools`), validates and installs the files from `overlay/` into the rootfs at their real paths, and enables/disables systemd units. It intentionally disables `NetworkManager`/`networking.service` in favor of `systemd-networkd` (see `usb-gadget` below). It also provisions default accounts directly (see below) and removes `/root/.not_logged_in_yet`, which otherwise triggers Armbian's interactive first-login wizard. If a gitignored `overlay/home/pi/.ssh/authorized_keys` exists on the build host it is installed for `pi`; the public repo never carries a key.
- **`overlay/`** — mirrors the target rootfs layout (e.g. `overlay/etc/foo` installs as `/etc/foo`). `customize-image.sh`'s `copy_overlay()` helper reads from `/tmp/overlay/<path>` and installs to `<path>` with explicit owner/group/mode. When adding a new overlay file, you must also add a corresponding `copy_overlay` call in `customize-image.sh` — files aren't installed automatically just by existing in `overlay/`.
- **`extensions/wifi7-mainline.sh`** — for `edge`/`bleedingedge`. Nothing is compiled; it (1) adds `CONFIG_IWLMLD=m` and the mt7925/ath12k/rtw89 and PHY symbols through a `custom_kernel_config__` hook using the `opts_m`/`opts_y` arrays; (2) copies BE200 (`iwlwifi-gl-c0-fm-c0-c1xx.ucode` + `.pnvm`) and RTL8922A firmware from kernel.org linux-firmware, pinned to tag `20260810`, into `/lib/firmware`; (3) supplies the bleedingedge boot glue the board file lacks (`BOOT_FDT_FILE=rockchip/rk3528-nanopi-zero2.dtb`, `SERIALCON=ttyS0`, `boot.cmd` console); (4) **fails the build** unless the installed config, `iwlmld.ko`, the firmware, the DTB's enabled `pcie@fe000000` node, `armbianEnv.txt`'s `fdtfile` and `boot.cmd`'s console are all as expected. Refuses `vendor` and `current`.
- **`extensions/iwlwifi-backport.sh`** — for `vendor` only (it now refuses any other branch). Compiles Intel `backport-iwlwifi` in-chroot post-build to add BE200 support, since the 6.1 vendor kernel doesn't ship it. Key things to know if touching this file:
  - It forces `CFG80211`/`MAC80211` to build as modules (`opts_m`) because the vendor defconfig ships them built-in, which would otherwise conflict with backport-iwlwifi's own modules at modpost time ("exported twice").
  - It detects at build time whether the target kernel uses `del_timer_sync()` or `timer_delete_sync()` and patches backport-iwlwifi accordingly, and disables backport's own `timer_delete()` shim when 6.1.y already declares it.
  - It works around a `depmod` quirk during `make install` by stubbing the host `depmod` for the duration of the install and running the real one afterward with the target kernel version.
  - `IWLWIFI_BACKPORT_REF`/`IWLWIFI_FIRMWARE_REF` take a plain branch name or commit hash; empty means the firmware repo's default branch head.
- **`linux-rk35xx-vendor.config`** — used by `vendor` only. **It is a full kernel config, not a fragment**: Armbian's `kernel-config.sh` selects `userpatches/<LINUXCONFIG>.config` as the whole `.config`. It is Armbian's vendor config plus a 4-line delta (`CFG80211=m`, `MAC80211=m`, `WL_ROCKCHIP` off). On a mainline branch `LINUXCONFIG` is `linux-rockchip64-<branch>`, so this file is silently ignored — which is why the mainline overrides live in the extension's `opts_*` hook instead of a second config file (a `userpatches/linux-rockchip64-edge.config` would replace Armbian's entire config).

## Device-specific behavior baked into the image

- **USB gadget (NCM)**: `overlay/usr/local/sbin/usb-gadget` configures a USB Ethernet (NCM) gadget via configfs (`usb-gadget.service`, a oneshot unit run early via `sysinit.target`). On the vendor kernel the UDC exists at boot. On mainline the USB-C port is a dwc3 in OTG mode whose role comes from the usb2phy's VBUS/ID sensing, so the UDC can appear later or only when a host is attached; the script exits 0 without a UDC and the udev rule `overlay/etc/udev/rules.d/90-usb-gadget-udc.rules` starts `usb-gadget-rebind.service` on every UDC add. The gadget serial comes from `/proc/device-tree/serial-number` (U-Boot writes it on both kernels), then `/proc/cpuinfo` (vendor only), then `/etc/machine-id`. `usb0` gets `192.168.7.1/24` and a DHCP pool `.10`–`.29` from `overlay/etc/systemd/network/20-usb0.network`.
- **Onboard Ethernet**: `overlay/etc/systemd/network/10-ethernet.network` matches `Name=end*`. There is one GMAC; the vendor kernel names it `end1` (its DT aliases it `ethernet1`, inherited from RK356x) and mainline names it `end0` (`rk3528-nanopi-zero2.dts` aliases it `ethernet0`). The unit sets `DHCP=yes` plus a statically-applied `172.16.0.1/24` — always present, not a fallback; multiple units on one LAN all claim `172.16.0.1`.
- **Default accounts**: `customize-image.sh` creates `pi` (password `pi`, member of `sudo` and `wireshark`) and locks `root`. **No SSH key is installed unless the builder provides the gitignored overlay file** — a reflash wipes any hand-installed key. This repo is public; change the `pi` password before exposing a unit.
- **Packet capture**: `wireshark-common` is installed with `install-setuid=true` pre-seeded so `pi` can run `dumpcap` without root.
- **sudo**: `overlay/etc/sudoers.d/pi-nopasswd-wifi` grants `pi` passwordless sudo for everything, matching WLANPi OS, which is what WLAN Commander's SSH layer assumes (`sudo -n`). The header comment records the trade-off.
- **Discovery**: `overlay/etc/avahi/services/nanopizero2.service` advertises `_http._tcp` (31415, `model`/`ver` TXT) and `_ssh._tcp` (22, `id=wlanpi`). WLAN Commander reads no TXT records; it keeps `_ssh._tcp` results whose **name contains `wlanpi`**, which is what `overlay/usr/local/sbin/wc-hostname` (run on the device, before avahi) provides: `wlanpi-nano-<last 4 of the SoC serial>`.
- **Networking manager choice**: `systemd-networkd` is authoritative; NetworkManager and ifupdown are disabled.

## Things that are true on mainline and were not on vendor

- The M.2 slot (PCIe) is enabled only by Armbian's out-of-tree `board-nanopi-zero2-enable-pcie.patch`; upstream never enables it. The verify hook proves it applied.
- There is no thermal sensor (no tsadc node upstream at any version), so no throttling and no `/sys/class/thermal` reading. Measure case temperature under load before field use.
- The kernel deb is `linux-image-<branch>-rockchip64`; the DTB lives under `/boot/dtb-<ver>/rockchip/`.
- The debug UART header (silkscreen `UART2DBG`, 3.3 V, 1500000 baud) is `ttyS2` on vendor and `ttyS0` on mainline. Same pins.
- Armbian's out-of-tree Wi-Fi driver harness must be off (`EXTRAWIFI=no`, done in `build.sh`): uwe5622, rtl8852bs, rtl8723ds, rtl8189es/fs and rtl8192eu all fail against 7.3's cfg80211 API. Not gated by version upstream; the first 7.3 build died on them 737 s in.
- The build prints `BRANCH_VALID_FOR_BOARD=no` for `bleedingedge` because the board file lists `vendor,current,edge`; that is expected and the extension supplies what the board file would.
