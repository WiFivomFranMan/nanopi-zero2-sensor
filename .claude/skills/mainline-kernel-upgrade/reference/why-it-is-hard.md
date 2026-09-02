# Why moving this box from vendor 6.1 to mainline 7.x is hard

Verified 2026-09-02 against kernel.org cgit (tags v6.18, v7.0, v7.1, v7.2, master = 7.3-rc1 and
linux-next), the Armbian tree at `v26.5.1` and `v26.11.0-trunk.30`, Debian package pages, and
lore. Fifteen research agents, each claim re-derived by a skeptic. Re-verify anything dated
before acting on it; the fast-moving parts are marked.

## The short version

Mainline is not missing the board. It is missing exactly the pieces a Wi-Fi sensor needs, and
the fork was welded to the vendor kernel at every joint.

## 1. Upstream status by kernel version (RK3528 / NanoPi Zero2)

| Landed in | What |
|---|---|
| v6.15 | eMMC (`sdhci`, `rk3528-dwcmshc`), SCMI clock |
| v6.16 | GMAC nodes, SD (`sdmmc`), PWM |
| v6.17 | GPU (lima) |
| **v6.18** | **The board DTS** (`rk3528-nanopi-zero2.dts`, Jonas Karlman), CPU OPP table (SCMI cpufreq), naneng combphy, power domains |
| v7.0 | PCIe Gen2x1 controller node (`pcie@fe000000`), combphy L1ss fix |
| v7.1 | OTP (with the tsadc trim cell), dwmac-rk rewrite by Russell King |
| **v7.2** | USB: `rockchip,rk3528-dwc3` OTG at `fe500000`, EHCI/OHCI, inno-usb2 PHY driver; board DTS enables USB (xHCI high-speed only, `extcon = <&usb2phy>`); watchdog node |
| 7.3-rc1 | **Nothing** for RK3528; `rk3528.dtsi` and the board DTS are byte-identical to v7.2 (linux-next too) |

Not upstream anywhere, nothing pending on lore (as of 2026-09-02):
- **tsadc / thermal zones.** No sensor, no throttling, no critical trip. The vendor tree
  throttles at 95/110 °C and shuts down at 120 °C; mainline runs the 2016 MHz OPP blind.
  Kwiboo has an unposted series in his WIP branches (blocked on OTP, which merged in 7.1).
- Hardware RNG, SFC (SPI flash).

## 2. The M.2 slot is Armbian-only

The upstream board DTS never enables `&pcie` / `&combphy` in any version. PCIe on the Zero2 comes
solely from Armbian's `patch/kernel/archive/rockchip64-<ver>/board-nanopi-zero2-enable-pcie.patch`
(Shlomi Marco, 2026-02-27: `&combphy okay; &pcie { pinctrl-0 = <&pciem1_pins>; reset-gpios =
<&gpio1 RK_PA2 GPIO_ACTIVE_HIGH>; }`, matching the vendor `rk3528-nanopi-rev01.dts`). Armbian
treats a failed patch as a warning; its hunk sits next to `&gmac1`, which `rk3528-14` also edits.
The verify hook decompiles the built DTB and fails the build if `pcie@fe000000` is not `okay`.

## 3. The BE200 is structurally dead on every stock Armbian mainline config

None of `linux-rockchip64-{current,edge,bleedingedge}.config` (v26.5.1 or trunk.30) sets
`CONFIG_IWLMLD`; it is a tristate with no Kconfig default. From v6.18 every FM/BE200
`IWL_DEV_INFO` entry and `cfg/rf-fm.o` sit under `#if IS_ENABLED(CONFIG_IWLMLD)`, so without it
`iwl_pci_find_dev_info()` returns NULL and probe fails with
`No config found for PCI dev 272b/… rfid=0x112200` (seen on a NanoPi R5C on 6.18/6.19). It does
**not** fall back to iwlmvm. Void and Debian both shipped this bug at 6.15/6.16.

## 4. Firmware (fast-moving)

The 7.x loader tries only core-named files `iwlwifi-gl-c0-fm-c0-c<N>.ucode`, from max down to min:

| Kernel | Accepts |
|---|---|
| v6.18 | ≤ c99 (files no longer exist) |
| v7.0 | c101 / c100 / API 100–102 |
| v7.1 | c102 / c101 / c100 |
| v7.2 | c102 … c106 |
| 7.3-rc1 | c102 … c107 |

Sources: `armbian-firmware` (installed by default) has **no** BE200 files at all (only AX210
`ty-a0-gf-a0` up to 89). Debian trixie stable `firmware-iwlwifi` 20250410-2 stops at API 97;
trixie-backports 20260622 has c101–c103; sid 20260810 adds c106. kernel.org linux-firmware tag
`20260810` has c101/c102/c103/c106 + `.pnvm`; master adds c107. Debian `firmware-iwlwifi`,
`-mediatek`, `-atheros` collide with `armbian-firmware` by **file overwrite** (no `Replaces`
either side); `firmware-realtek` is a declared `Conflicts`. `BOARD_FIRMWARE_INSTALL=-full`
would pull linux-firmware `main` unpinned. Hence: keep `armbian-firmware` (it has mt7925 and
WCN7850), copy BE200 + RTL8922A from the pinned tag.

## 5. USB on 7.2+ panics without two unmerged patches

Daniel Bozeman's pmdomain pair (2026-03-31, thread stalled 2026-04-28): idle-only domains
(PD_VO/PD_VPU/PD_RKVENC) and an `-EPROBE_DEFER` teardown cause a synchronous external abort in
`rockchip_pmu_set_idle_request` once the board DTS carries the gpio4-controlled `usb2_host_5v`
regulator that v7.2 added. Armbian carries them as
`rk3528-pmdomain-rockchip-fixes-for-working-usb-rk3528.patch` on 7.2/7.3. The USB-C NCM gadget
on upstream 7.2 DT has no published report for this board.

## 6. Armbian pin trap (fast-moving)

- `v26.5.1`: current 6.18, edge **7.0** (EOL, frozen at 7.0.14), bleedingedge **7.1-rc3** (EOL).
- `v26.11.0-trunk.30` = `ee00ac7c8a7ef07d5f258acb787638f283c00a0a` (2026-08-31): edge **7.2**,
  bleedingedge **7.3**. First tag with that mapping; no stable Armbian tag newer than v26.5.1.
- Armbian main deleted the 7.0 and 7.1 patch archives; trunk tags get pruned (only 4/11/22/30
  survived for v26.11.0). `KERNEL_MAJOR_MINOR` overrides are silently reset.

## 7. bleedingedge is not a declared target for the board

`config/boards/nanopi-zero2.csc`: `KERNEL_TARGET="vendor,current,edge"`; its
`post_family_config__nanopi_zero2_mainline` and `post_family_tweaks__nanopi_zero2_serial_console`
match `current | edge)` only. A bleedingedge image would boot with `rk3528-nanopi-rev01.dtb`
(vendor name, absent from mainline) and `console=ttyS2`: a dead board with no serial. The build
only warns (`BRANCH_VALID_FOR_BOARD=no`). The extension's `post_family_config_branch_bleedingedge__`
hook and `extension_finish_config__` assertion cover this.

## 8. Fork coupling to the vendor kernel (fixed on `mainline-7.3`)

- `BRANCH=vendor` hardcoded; one Armbian pin for everything.
- `userpatches/linux-rk35xx-vendor.config`: a **full config replacement** keyed on the vendor
  `LINUXCONFIG` name (Armbian's `kernel-config.sh` copies `userpatches/$LINUXCONFIG.config`
  wholesale as `.config`). Silently ignored on mainline. The old CLAUDE.md called it a fragment.
- `iwlwifi-backport.sh`: on 7.x would install its own cfg80211/mac80211/iwlwifi into
  `updates/`, force `INSTALL_HEADERS`, and assert `iwlmvm.ko`. Had no branch guard.
- `10-ethernet.network` matched `end1`; mainline's `ethernet0 = &gmac1` alias yields `end0`.
- `usb-gadget` read a `Serial:` line from `/proc/cpuinfo` that mainline arm64 lacks, and
  assumed the UDC exists at sysinit (mainline dwc3 OTG registers it from a role-switch work item).
- avahi `ver=` drifted from `IMAGE_VERSION`.

## 9. Ethernet on mainline

PHY identity is disputed (RTL8211F per the vendor DT comment and one status page; YT8531S
Motorcomm per the Armbian PR author). Armbian's automatic config rewrite (2026-05-04) dropped
`CONFIG_MOTORCOMM_PHY=y`; PR 9912 restoring it is still open; `CONFIG_REALTEK_PHY` is absent
from edge/bleedingedge too. The extension builds both in. PHY reset ordering is a known
unresolved mainline issue (reset-gpios on the PHY node are toggled only after the PHY ID is
read); Armbian's `rk3528-14` moves the reset to the MAC node as a workaround. Upstream DTS uses
`rgmii-id` (MAC delays 0/0, PHY supplies delays); Armbian's `rgmii-delays` WIP patch is disabled
because it no longer applies, not because of a measured fault.

## 10. Edge U-Boot artifact cache bug

armbian/build#9508 (open): a cached `uboot-nanopi-zero2-edge` artifact shipped a `u-boot.itb`
with a 0-byte FDT ("No valid device tree binary found"). `WC_IGNORE_CACHE=yes` on the first
build; `dumpimage -l` on `u-boot.itb` afterwards.

## 11. 7.3 specifically

Armbian's "prepare 7.3 patches" PR (2026-08-31): "all out-of-tree drivers broke — again …
fixing is out of scope". The `lt 7.3`-gated Realtek out-of-tree drivers are skipped. Not needed
by this image.

## 12. What was never verified on hardware (as of 2026-09-02)

- Any 7.x kernel booting this board under the Radxa vendor U-Boot (every published report is
  6.18 current: PRs 9453/9500/9597/9608/9785, all by one author; a 7.0-rc6 boot on Kwiboo's tree
  by one forum user with an MT7925).
- A BE200 on in-tree iwlwifi on this SoC at all.
- The USB-C gadget on the upstream 7.2 DT.
- WLAN Commander's monitor-prep sequence (same-PHY managed scan with the monitor vif up, targeted
  UNII-7/8 scan, managed down, `otherbss`) under iwlmld, a chanctx driver, after mac80211's
  monitor rework in 7.0/7.2/7.3.
- Whether the M.2 E-key slot carries USB 2.0 (Bluetooth on combo cards) — the wiki says only
  "PCIe 2.1 x1".
- Gigabit on `end0` under the mainline DT (link reports exist; no iperf).

## What mainline buys once the above is handled

In-tree `iwlmld` (same sniffer generation as backport core102 but eight months newer: firmware
core 106, VHT sniffer decode, EHT TB sniffer fix, BAID fix); cfg80211/mac80211 no longer replaced
in `updates/` (which on 6.1 isolated every other mac80211 driver from the stack it was built
against, with `MODVERSIONS=y`); EHT radiotap (6.4), U-SIG 320 MHz defs (6.7), monitor on
disabled channels (6.9/6.11), `SKIP_TX` (6.13), the 2026 chanctx-monitor fixes (7.0/7.2/7.3);
and the drivers for every other Wi-Fi 7 card (see `wifi7-cards.md`).
