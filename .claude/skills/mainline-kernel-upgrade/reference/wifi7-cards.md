# Wi-Fi 7 cards on a Linux sniffer: what works at kernel 7.2 / 7.3

Verified 2026-09-02 from kernel sources at v7.2 and 7.3-rc1, linux-firmware, and Debian package
lists. "Monitor" means mac80211 monitor mode with radiotap output. "Max width" is the widest
channel the driver advertises in any mode.

## Board limits before any driver (NanoPi Zero2)

- One M.2 Key-E 2230 slot: **PCIe 2.1 x1 only** per the FriendlyElec wiki (USB on the slot, and
  therefore Bluetooth on combo cards, is unverified). 3.3 V rail shared with eMMC/SD/Ethernet.
- One USB 2.0 Type-A host port: **480 Mbit/s ceiling** for any USB stick, before it captures a
  single 160 MHz frame.
- One USB 2.0 Type-C device port (the NCM gadget). Not a host port.

## Per-chipset table

| Card | Driver / op-mode | In-tree since | Monitor | Max width | Firmware files | Firmware source on this image | CONFIG symbols | Gotchas |
|---|---|---|---|---|---|---|---|---|
| **Intel BE200** (8086:272b, gl-c0-fm-c0) | `iwlwifi` + `iwlmld` | iwlmld v6.15 | yes; EHT radiotap, 320 MHz-1/-2 U-SIG, PHY air-sniffer notification | **320 MHz** | `iwlwifi-gl-c0-fm-c0-c<N>.ucode` + `iwlwifi-gl-c0-fm-c0.pnvm` | pinned linux-firmware tag (extension) | `IWLWIFI=m IWLMLD=m` (keep `IWLMVM=m`) | `IWLMLD` has no default and is absent from every Armbian config; 7.2 loads c102–c106 only; regulatory needs a station scan on the same PHY with the monitor vif up (see `intel-wifi-monitor` memory); the fork's `bt_coex_active`/`power_scheme` findings were backport-specific |
| **MediaTek MT7925** PCIe (`mt7925e`) / USB (`mt7925u`; Netgear Nighthawk A9000 0846:9072, A8500 0846:9050 from 7.2) | `mt7925` (firmware sniffer) | v6.7 | yes (firmware `SNIFFER` cmd) | **160 MHz** (`is_320mhz_supported()` is `chip == 0x7927`) | `mediatek/mt7925/WIFI_RAM_CODE_MT7925_1_1.bin`, `WIFI_MT7925_PATCH_MCU_1_1_hdr.bin` (+BT) | `armbian-firmware` (already present) | `MT7925E=m MT7925U=m` | USB variant is capped by the USB 2.0 port; firmware vintage vs 7.2's sniffer command refinements unverified |
| **Qualcomm WCN7850 / QCNCM865** (M.2 PCIe) | `ath12k` | v6.3; **monitor v6.16** | yes; MCS/TLV monitor fixes landed in 7.1/7.2 | 320 MHz capability wired; **monitor at 320 unverified** | `ath12k/WCN7850/hw2.0/{amss,board-2,m3}.bin` (+`ncm865/` for QCNCM865) | `armbian-firmware` (base files; `ncm865/` present in linux-firmware tag 20260810) | `ATH12K=m` (needs `PCI`, MSI) | PCIe only; MSI-only with single-vector fallback; 36-bit streaming / 32-bit coherent DMA masks; check `dmesg | grep 'MSI vectors'` on first bring-up; 3.3 V rail budget for a 1 A TX peak unverified |
| **Realtek RTL8922AE** (PCIe) / **RTL8922AU** (USB; TP-Link Archer TBE400UH 3625:010a) | `rtw89` (`rtw89_8922ae`, `rtw89_8922au`) | AE 6.x; **AU v7.2** (rtw89 USB core v6.17) | yes (pure-monitor vif; 7.2 sniffer bits) | **160 MHz** (chip_info advertises 20/40/80/160 only) | `rtw89/rtw8922a_fw{,-1..-4}.bin` | pinned linux-firmware tag (extension); **not** in armbian-firmware, and `armbian-firmware` Conflicts with Debian `firmware-realtek` | `RTW89=m RTW89_8922AE=m RTW89_8922AU=m` | No `8922AU` line in any Armbian config (symbol did not exist before 7.2); no out-of-tree fallback exists (morrownr repo 404, lwfinger stale); USB path has no RX aggregation |
| Older Realtek USB (8851BU, 8852AU/BU/CU) | `rtw89` USB | v6.17 (8851BU/8852BU), 7.0 (8852AU/CU) | yes | 160 | `rtw89/rtw8851b_fw*`, `rtw8852*_fw*` | `armbian-firmware` has 8852a/b/c | `RTW89_8851BU RTW89_8852AU RTW89_8852BU RTW89_8852CU` | Wi-Fi 6/6E parts, listed because the extension enables them |

**No USB Wi-Fi 7 stick captures 320 MHz.** Only the BE200 (and, capability-wise, WCN7850) do.

## Adding a card: the recipe

1. **Symbol.** Add it to `custom_kernel_config__wifi7_mainline` in
   `userpatches/extensions/wifi7-mainline.sh` via `opts_m+=("…")`. Check the Kconfig at the
   target kernel for `depends on` (e.g. `RTW89_8922AU` selects `RTW89_USB`; `ATH12K` needs `PCI`).
2. **Verify line.** Add `CONFIG_<SYM>=m` to the `for sym in …` list in
   `post_install_kernel_debs__900_wifi7_verify`. `olddefconfig` drops symbols silently; this is
   the only place that notices.
3. **Firmware.** Check `armbian-firmware` first (`gh api repos/armbian/firmware/contents/<dir>`).
   If absent, extend `post_install_kernel_debs__500_wifi7_firmware` to copy the files from the
   pinned linux-firmware tag (confirm they exist at that tag via `WHENCE`); add a presence check
   to the verify hook. Never `apt-get install firmware-*` beside `armbian-firmware`: `-iwlwifi`,
   `-mediatek`, `-atheros` collide by file overwrite (dpkg unpack error), `-realtek` is a
   declared Conflict and would remove `armbian-firmware`.
4. **Unit test.** Add the symbol and firmware file to `tests/wifi7-mainline-hooks.sh`'s good tree,
   and one "FAILS when missing" case.
5. **Hardware proof.** `lsmod`, `dmesg | grep -i <driver>`, `iw list | grep -A3 'Supported
   interface modes'` (monitor listed), widest `* 320 MHz` / `160 MHz` under the band's channel
   list, then a real capture on the widest channel with `tcpdump -i <mon> -c 100`.
6. **WLAN Commander.** Record the width limit in core's `DriverCapabilities` /
   `monitor_width_limits()` so the app never asks the card for more than it can do (the
   `31-multi-vendor-set-freq.md` doc in the WLAN Commander repo is the register).

## Firmware pin

`WIFI7_FIRMWARE_REF=20260810` (kernel.org linux-firmware tag). Contents relevant here:
`intel/iwlwifi/iwlwifi-gl-c0-fm-c0-{c101,c102,c103,c106}.ucode` and `.pnvm` (the tree moved
iwlwifi files under `intel/iwlwifi/` in 2026; WHENCE `Link:` entries give them their top-level
names on install, and the driver requests the top-level name — the hook copies them there),
`mediatek/mt7925/*`, `ath12k/WCN7850/hw2.0/{amss,board-2,m3}.bin` + `ncm865/`,
`rtw89/rtw8922a_fw-4.bin`. master (after the tag) adds `c107`. Bump only after checking the
target kernel's accepted range, and change the verify hook's `102..106` window if 7.2 support
is dropped.
