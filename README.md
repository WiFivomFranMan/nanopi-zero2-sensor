# NanoPi Zero2 Sensor Image

A custom, minimal Armbian image build for the FriendlyElec NanoPi Zero2 (Rockchip RK35xx), configured as a headless Wi-Fi scanning/sensor device ("Intuitibits NanoPi Zero2 sensor image").

This repository does not contain a full Armbian checkout. It's a thin build wrapper (`build.sh`) plus a set of `userpatches/` that get layered into a freshly cloned upstream [Armbian `build`](https://github.com/armbian/build) tree at build time.

## Status

There is no CI pipeline, automated test suite, or published release process in this repository. The current image version is `1.0.0` (set in `build.sh`). Validation is done by running a full build and testing the resulting image on hardware, or by reasoning about the shell scripts directly.

## Supported hardware

**Confirmed:**

- FriendlyElec NanoPi Zero2, built via Armbian's `BOARD=nanopi-zero2 BRANCH=vendor` target.

**Optional / additional:**

- Intel BE200 Wi-Fi 6E, connected via M.2 (the NanoPi Zero2 does not include BE200 support in its stock vendor kernel). Support is added by compiling `backport-iwlwifi` in-chroot; see [Intel iwlwifi backport (BE200)](#intel-iwlwifi-backport-be200) below. This is enabled by default in `build.sh` via `ENABLE_EXTENSIONS=iwlwifi-backport`, and the build fails if the driver/firmware can't be built and installed.

The kernel config fragment (`userpatches/linux-rk35xx-vendor.config`) also carries a broad set of other wireless driver options (Atheros, Broadcom, MediaTek, Realtek, etc.) inherited from the vendor `rk35xx` defconfig. These are enabled as loadable modules by the vendor defconfig itself, not added by this repo, and are not verified against specific hardware here.

## Base system

Set in `build.sh`:

| Setting | Value |
|---|---|
| Armbian source | `https://github.com/armbian/build.git`, pinned to tag `v26.5.1` (`ARMBIAN_TAG`) |
| Board | `nanopi-zero2` |
| Kernel branch | `vendor` |
| Debian release | `trixie` (Debian 13) |
| Image type | `BUILD_MINIMAL=yes`, `BUILD_DESKTOP=no` (console-only, no desktop environment) |
| Kernel config | `KERNEL_CONFIGURE=no` — no interactive menuconfig; config comes from the vendor defconfig plus `userpatches/linux-rk35xx-vendor.config` |
| Extensions | `ENABLE_EXTENSIONS=iwlwifi-backport` |

## Major customizations

### Intel iwlwifi backport (BE200)

`userpatches/extensions/iwlwifi-backport.sh` is an Armbian build extension (hooked via `extension_prepare_config__*`, `custom_kernel_config__*`, and `post_install_kernel_debs__*`) that, after the kernel is built and installed:

- Clones and builds Intel's `backport-iwlwifi` (default ref: `origin/release/core98` from `git.kernel.org/.../backport-iwlwifi.git`) against the target kernel's headers, inside the chroot.
- Detects whether the target kernel uses `del_timer_sync()` or the renamed `timer_delete_sync()` (v6.2+) by inspecting the kernel headers directly, and patches `backport-iwlwifi` source accordingly, since vendor kernels backport APIs selectively rather than tracking upstream version numbers.
- Works around a `depmod` quirk where backport's `make install` invokes the *build host's* `depmod` by absolute path (which would target the wrong kernel version inside the chroot): it temporarily stubs out `depmod` on disk during `make install`, then restores it and runs `depmod` explicitly against the correct target kernel version.
- Clones `linux-firmware` (from `git.kernel.org/.../linux-firmware.git`) and installs the BE200 ucode (`iwlwifi-gl-c0-fm-c0-*.ucode`) and any matching `.pnvm` files into `/lib/firmware/`.
- Verifies afterward that `iwlwifi.ko`, `iwlmvm.ko`, and the BE200 firmware files are actually present, failing the build otherwise.

### Required kernel configuration changes

The vendor defconfig ships `CFG80211`/`MAC80211` built directly into the kernel image. `iwlwifi-backport.sh`'s `custom_kernel_config__iwlwifi_backport_wifi_as_modules()` hook forces both to build as loadable modules (`opts_m`) instead, because `backport-iwlwifi`'s own `cfg80211.ko`/`mac80211.ko` would otherwise conflict with the built-in symbols at modpost time ("exported twice"). This is also reflected statically in `userpatches/linux-rk35xx-vendor.config` (`CONFIG_CFG80211=m`, `CONFIG_MAC80211=m`).

That config fragment additionally carries a broad set of enabled networking, netfilter, USB-gadget, and wireless driver options for the `rk35xx`/`vendor` kernel branch.

### Firmware installation

BE200 firmware (`iwlwifi-gl-c0-fm-c0-*.ucode` and matching `.pnvm` files) is cloned from the upstream `linux-firmware` repository and copied into `/lib/firmware/` as part of the `iwlwifi-backport` extension (see above). No other firmware is installed by this repo beyond what Armbian's own base image build provides.

### Avahi service advertisement

`userpatches/overlay/etc/avahi/services/nanopizero2.service` advertises, over mDNS:

- `_http._tcp` on port `31415`, with TXT records `model=NanoPi Zero2` and `ver=1.0.0`.
- `_ssh._tcp` on port `22`, with TXT record `id=wlanpi`.

`avahi-daemon` and `avahi-utils` are installed and `avahi-daemon.service`/`avahi-daemon.socket` are enabled by `userpatches/customize-image.sh`.

### systemd-networkd configuration

`systemd-networkd.service` is enabled and is authoritative for network interface configuration; `NetworkManager.service` and `networking.service` are explicitly disabled in `customize-image.sh`. The only network unit shipped is `userpatches/overlay/etc/systemd/network/20-usb0.network`, matching interface `usb0`:

- Static address `192.168.7.1/24`
- Built-in DHCP server (`DHCPServer=yes`), pool offset `10`, pool size `20` (i.e. `192.168.7.10`–`192.168.7.29`)
- `ConfigureWithoutCarrier=yes`, no DNS/router advertised to clients

### USB gadget networking

`userpatches/overlay/usr/local/sbin/usb-gadget` configures a USB gadget via configfs at `/sys/kernel/config/usb_gadget/nanopi-zero2`, run by `usb-gadget.service` (a oneshot unit, `WantedBy=sysinit.target`, so it runs very early — before normal network setup). As implemented, it sets up:

- Device strings: manufacturer `FriendlyElec`, product `NanoPi Zero2`, serial number from `/proc/cpuinfo` (falling back to `/etc/machine-id`)
- USB IDs: `idVendor=0x2207`, `idProduct=0x0019`
- A single NCM (USB Ethernet) function, bound as `usb0`

The resulting `usb0` interface is what `20-usb0.network` (above) configures.

## Host build requirements

Confirmed from `build.sh` itself:

- `bash`, `git`, `rsync`
- Sufficient disk space and time for a full kernel + rootfs build

Beyond that, host OS requirements are whatever upstream Armbian's `compile.sh` needs for the pinned tag (`v26.5.1`) — this repo does not add any additional host constraints of its own. Consult [Armbian's build documentation](https://docs.armbian.com/Developer-Guide_Build-Preparation/) for supported host platforms.

## Building

```bash
./build.sh
```

The script is idempotent and safe to re-run. It:

1. Clones `https://github.com/armbian/build.git` into `./build/` if not already present.
2. Fetches tags and force-checks-out `ARMBIAN_TAG` (`v26.5.1`) in the `build/` tree — **this discards any local changes there**.
3. `rsync --delete`s `userpatches/` into `build/userpatches/` — this repo's `userpatches/` is the single source of truth; anything not present here is removed from the Armbian tree's copy.
4. Deletes any previous `.img*` artifacts in `build/output/images/`.
5. Runs Armbian's `./compile.sh` with:
   ```
   BOARD=nanopi-zero2 BRANCH=vendor RELEASE=trixie BUILD_MINIMAL=yes \
   BUILD_DESKTOP=no KERNEL_CONFIGURE=no ENABLE_EXTENSIONS=iwlwifi-backport
   ```
6. Renames the resulting image, checksum, and build log.

The `build/` directory is gitignored and not part of this repo — don't edit files under it expecting changes to persist. Edit `userpatches/` instead and re-run `build.sh`.

## Build artifacts and output

Artifacts are written to `build/output/images/` and renamed to:

```
intuitibits-nanopi-zero2-v<IMAGE_VERSION>.img       # the flashable image
intuitibits-nanopi-zero2-v<IMAGE_VERSION>.img.sha   # checksum
intuitibits-nanopi-zero2-v<IMAGE_VERSION>.img.txt   # build log
```

with `<IMAGE_VERSION>` taken from `build.sh` (currently `1.0.0`). Armbian's own, more detailed compile logs and any additional build artifacts (kernel/u-boot `.deb` packages, etc.) remain under `build/output/` in Armbian's normal layout and are not renamed or moved by this wrapper.

## Repository structure

```
build.sh                                    Build wrapper (see above)
userpatches/
  customize-image.sh                        Armbian chroot customization hook: installs
                                             packages, installs overlay/ files, enables/
                                             disables systemd units
  overlay/                                  Mirrors the target rootfs layout; installed by
                                             customize-image.sh's copy_overlay() helper
    etc/avahi/services/nanopizero2.service   mDNS service advertisement
    etc/sudoers.d/pi-scanning                Scoped passwordless sudo for the `pi` user
    etc/systemd/network/20-usb0.network      systemd-networkd config for usb0
    etc/systemd/system/usb-gadget.service    USB gadget oneshot unit
    usr/local/sbin/usb-gadget                USB NCM gadget setup script
  extensions/
    iwlwifi-backport.sh                      Armbian extension: builds Intel BE200 driver
                                              + firmware in-chroot
  linux-rk35xx-vendor.config                 Kernel defconfig fragment (rk35xx/vendor branch)
```

Adding a new file to `overlay/` also requires adding a corresponding `copy_overlay` call in `customize-image.sh` — files are not installed automatically just by existing in `overlay/`.

Packages installed into the image by `customize-image.sh`: `tcpdump`, `avahi-daemon`, `avahi-utils`, `iw`, `wireless-tools`.

`overlay/etc/sudoers.d/pi-scanning` grants the `pi` user passwordless `sudo` for exactly `iw`, `ip`, and `tcpdump` — the minimum needed for Wi-Fi scanning/packet capture without full root.

## Changing the image version or build settings

- **Image version**: bump `IMAGE_VERSION` at the top of `build.sh`. Keep it in sync with the `ver=` TXT record in `userpatches/overlay/etc/avahi/services/nanopizero2.service` — the two are not linked automatically.
- **Armbian version**: change `ARMBIAN_TAG` in `build.sh`.
- **Board/branch/release/image type**: edit the `./compile.sh` invocation in `build.sh` directly (`BOARD`, `BRANCH`, `RELEASE`, `BUILD_MINIMAL`, `BUILD_DESKTOP`, `KERNEL_CONFIGURE`, `ENABLE_EXTENSIONS`).
- **iwlwifi-backport source pins**: `userpatches/extensions/iwlwifi-backport.sh` reads `IWLWIFI_BACKPORT_REPOSITORY`, `IWLWIFI_BACKPORT_REF`, `IWLWIFI_FIRMWARE_REPOSITORY`, and `IWLWIFI_FIRMWARE_REF` from the environment, falling back to the defaults documented in [Reproducibility notes](#reproducibility-notes) below.

## Flashing the image

Use any standard image-flashing tool, for example [balenaEtcher](https://etcher.balena.io/) or `dd`:

```bash
# Example only — replace /dev/sdX with your actual SD card device.
# Double- and triple-check the target device before running this:
# writing to the wrong device will destroy its data irrecoverably.
sudo dd if=intuitibits-nanopi-zero2-v1.0.0.img of=/dev/sdX bs=4M status=progress conv=fsync
```

Verify you've identified the correct device (e.g. with `lsblk` or `diskutil list`) before flashing, and verify the image checksum against the accompanying `.img.sha` file first.

## First boot and discovery

Based on what's configured in `userpatches/`:

- Connecting the NanoPi Zero2 to a host machine via USB brings up a USB Ethernet (NCM) interface (`usb0`) on the device, configured very early in boot (before normal networking, via `sysinit.target`).
- The device's side of that link is `192.168.7.1/24`; it runs a DHCP server that will hand the host an address in `192.168.7.10`–`192.168.7.29`.
- On any network reachable via mDNS (including over the USB link, once the host has an address), the device advertises itself via avahi as `_http._tcp` (port `31415`) and `_ssh._tcp` (port `22`), discoverable as `<hostname>.local` with `avahi-browse` or similar mDNS tooling.
- The `pi` user has passwordless `sudo` scoped to `iw`, `ip`, and `tcpdump` for Wi-Fi scanning tasks.

This repo does not configure default login credentials, hostname, or SSH host keys — those follow Armbian's own first-boot behavior (e.g. its standard first-login setup wizard), which is not modified here.

## Verification and troubleshooting

**Ethernet / USB gadget connectivity**
- On the device: `systemctl status usb-gadget.service` and check `cat /sys/kernel/config/usb_gadget/nanopi-zero2/UDC` is non-empty.
- On the host: confirm a new USB Ethernet interface appeared, and that it received a DHCP lease in `192.168.7.10`–`192.168.7.29`.
- `ping 192.168.7.1` from the host once it has an address.

**Confirming the backported iwlwifi modules loaded**
- `lsmod | grep -E 'iwlwifi|iwlmvm|cfg80211|mac80211'` — `cfg80211` and `mac80211` should appear as separate modules (not built-in), per the forced-modules change above.
- `dmesg | grep -i iwlwifi` for load/probe messages.

**Confirming BE200 detection**
- `lspci -k` should show the Intel Wi-Fi device (M.2, over PCIe) with `iwlwifi` bound as the kernel driver.
- `ip link` / `iw dev` should list a corresponding `wlan*` interface.
- `dmesg | grep -i "iwlwifi.*[0-9a-f]\{4\}:[0-9a-f]\{2\}:[0-9a-f]\{2\}"` or similar for the driver's own detection/firmware-load messages.

**Diagnosing missing firmware**
- `dmesg | grep -iE 'firmware|iwlwifi'` — look for "Direct firmware load ... failed" errors.
- Confirm the expected files exist on-device: `ls /lib/firmware/iwlwifi-gl-c0-fm-c0-*`.
- If missing, the `iwlwifi-backport` extension either didn't run (check `ENABLE_EXTENSIONS`) or failed during the build — check the build log (below).

**Locating build logs**
- The renamed top-level summary log: `build/output/images/intuitibits-nanopi-zero2-v<IMAGE_VERSION>.img.txt`.
- Armbian's own detailed per-step compile logs live under `build/output/logs/` — this location is not controlled or renamed by this repo's wrapper.

## Reproducibility notes

- The Armbian build tree itself is pinned to an immutable tag: `ARMBIAN_TAG=v26.5.1` in `build.sh`.
- `backport-iwlwifi` is **not** pinned to an immutable commit by default — `IWLWIFI_BACKPORT_REF` defaults to `origin/release/core98`, a moving branch reference. Different builds run at different times may pick up different `backport-iwlwifi` commits.
- `linux-firmware` is similarly unpinned by default — `IWLWIFI_FIRMWARE_REF` defaults to empty, which the extension treats as "shallow-clone the default branch HEAD." Firmware content can therefore change between builds without any change to this repo.
- For a fully reproducible build, set `IWLWIFI_BACKPORT_REF` and `IWLWIFI_FIRMWARE_REF` to specific commit hashes in the environment before running `build.sh`.

## Releases

There is no automated release pipeline (no CI configuration was found in this repository). To get an image, build it locally per [Building](#building) above. The artifact to flash is:

```
intuitibits-nanopi-zero2-v<IMAGE_VERSION>.img
```

verified against the accompanying `.img.sha` checksum file. The `.img.txt` file is the build log, not a flashable artifact.

## License

TODO — no license file is currently present in this repository.

## Contributing

TODO — no contribution guidelines are currently present in this repository. See [CLAUDE.md](CLAUDE.md) for repository conventions used by AI coding assistants.
