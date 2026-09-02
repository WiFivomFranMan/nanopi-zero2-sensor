# Build history: the first mainline image (2026-09-02)

Six attempts on the NUC (16 cores, ccache warm after the first), all `WC_BRANCH=bleedingedge`.
Each failure was one stage later than the previous one; none was in this repo's own code except
where the verify hooks did what they were written for. Keep this list: it is the shortest
description of what Armbian's 7.3 transition looks like from a downstream image.

| # | Fork commit | Armbian pin | Died at | Cause | Fix |
|---|---|---|---|---|---|
| 1 | `adae556` | trunk.30 | kernel compile, 737 s | six of Armbian's out-of-tree Wi-Fi drivers (uwe5622, rtl8852bs, rtl8723ds, rtl8189es/fs, rtl8192eu) fail on 7.3's cfg80211 `remain_on_channel`/`mgmt_tx` signatures; no upper version gate | `EXTRAWIFI=no` on mainline branches (`f862b63`) |
| 2 | `f862b63` | trunk.30 | firmware hook | linux-firmware moved iwlwifi files to `intel/iwlwifi/` (top-level names are WHENCE `Link:` entries) | look there first (`2eb472b`) |
| 3 | `2eb472b` | trunk.30 | **verify hook**: `pcie@fe000000` disabled in the DTB | trunk.30 has no `patch/kernel/archive/rockchip64-7.3/` at all; Armbian silently applies nothing; the M.2 slot would have been dead | pin `main@6d07521a`, first commit with the 7.3 archive (`79aac17`) |
| 4 | `79aac17` | `6d07521a` | kernel patching, 214/215 | Armbian's `board-orangepi-5-es8388-route-mclk-to-io.patch` (unrelated board) has a space-indented hunk against a tab-indented file; a failed regular patch is fatal | same-named override under `userpatches/kernel/` (`4871738`) — **did not work** |
| 5 | `4871738` | `6d07521a` | kernel patching, 214/215 | the patcher iterates the core root last and keys by file name, so core shadows user | `userpatches/kernel-overrides/` copied over the core file at `extension_finish_config__` (`7fd4469`) |
| 6 | `7fd4469` | `6d07521a` | — | — | **Build complete**, both verify hooks green, offline check green |

Result: `intuitibits-nanopi-zero2-v1.1.0-wc1-bleedingedge.img.xz` (404 MB; 2.5 GB raw),
kernel `7.3.0-rc1-bleedingedge-rockchip64`, U-Boot deb `linux-u-boot-nanopi-zero2-bleedingedge`
(Radxa 2017.09 tree, `u-boot.itb` FDT 7992 bytes), `armbian-firmware 26.11.0-trunk`.

Offline check (on the NUC, loop-mounted): every config symbol present; `iwlmld.ko`,
`mt7925u.ko`, `ath12k.ko`, `rtw89_8922au.ko` installed; DTB `pcie@fe000000` `okay` with
`reset-gpios = <gpio1 2 0>` and `pinctrl-0`, `usb@fe500000` `otg` high-speed `okay`;
`/lib/firmware/iwlwifi-gl-c0-fm-c0-{c101,c102,c103,c106}.ucode` + `.pnvm`, `rtw89/rtw8922a_fw*`,
`mediatek/mt7925/*`, `ath12k/WCN7850/hw2.0/*`; `armbianEnv.txt` `fdtfile=rockchip/rk3528-nanopi-zero2.dtb`,
`boot.cmd` `console=ttyS0,1500000`, DTB `stdout-path = "serial0:1500000n8"`; `Name=end*`, udev
rebind rule, `usb-gadget.service` in sysinit, `wc-hostname`/`avahi`/`networkd` enabled,
avahi `ver=1.1.0-wc1`, user `pi` with no authorized key.

Not yet done: anything on hardware (`checklists/hardware-bringup.md`). The vendor 1.0.1-wc2
image is under `build/output/images/archive/` on the NUC.

Things learned that the research had wrong, now corrected in the other reference files:
Armbian's out-of-tree drivers are not version-gated off for 7.3; a same-named `userpatches`
kernel patch does not override the core one; the trunk.30 tag predates the 7.3 patch archive;
linux-firmware keeps iwlwifi files under `intel/iwlwifi/`. Armbian's own 0-byte-FDT check on
U-Boot now runs at build time (`u-boot for nanopi-zero2::bleedingedge [ Checking for 0-byte DTB ]`),
so armbian/build#9508 is mitigated on this pin.
