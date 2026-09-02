---
name: mainline-kernel-upgrade
description: Build, verify and bring up the NanoPi Zero2 (RK3528) sensor image on a mainline 7.x kernel instead of the Rockchip 6.1 vendor kernel, keep the Intel BE200 (and other Wi-Fi 7 cards) working, and know what is still out-of-tree. Use for any kernel bump, any "why does the BE200 not probe on mainline", and for adding a new Wi-Fi card to the image.
argument-hint: "[edge|bleedingedge] [phase]"
---

# Mainline kernel upgrade for the NanoPi Zero2 sensor

You are working in `WiFivomFranMan/nanopi-zero2-sensor`, an Armbian wrapper. `build.sh` plus
`userpatches/` is the whole product; the kernel, U-Boot and rootfs come from Armbian at a pinned
commit. Branch argument: `$ARGUMENTS` (default `bleedingedge`; `edge` is 7.2.y).

## Rules that override everything below

1. **The live sensor `wlanpi-nano-5430.local` may be in use by another test.** Do not log in,
   scan from it, reboot it, or flash it unless the user has said in this conversation that it is
   free. Its address moves with DHCP (do not use a remembered IP). Even a "read-only" SSH login
   was flagged as interference during the antenna campaign in September 2026.
2. **Credentials are password-only unless the builder added a key.** The image creates `pi` with
   password `pi`, locks `root`, gives `pi` passwordless sudo for everything, and installs **no**
   `authorized_keys`. `ssh -o BatchMode=yes` can never succeed on a stock image; a reflash wipes any
   hand-installed key. To make bring-up scriptable, put a public key in the gitignored
   `userpatches/overlay/home/pi/.ssh/authorized_keys` *before* building.
3. **Nothing here runs on this Mac except editing and linting.** The build needs the Ubuntu build
   server (`kevin@10.80.1.17`, `~/nanopi-fork/sensor`); it is not always reachable (office
   network vs lab). Every step marked **HUMAN** needs the user: the NUC, the board, an SD card, a
   serial adapter, or a test window.
4. **Fail loudly, never warn.** Armbian treats a failed patch as a warning and drops unknown
   config symbols silently. The `wifi7-mainline` extension turns the known silent failures into
   build failures; if you add a card or a patch, add its check to the verify hook in the same
   change.
5. **Do not create `userpatches/linux-rockchip64-<branch>.config`.** That file is a full config
   replacement, not a fragment; use `opts_m`/`opts_y` in the extension's `custom_kernel_config__`
   hook.

## Decision rule: which branch

- `bleedingedge` (7.3-rc, fixed tag) and `edge` (7.2.y, rolling stable) carry **identical**
  RK3528 device trees and the same Armbian rk3528 patch set. 7.3 adds only newer Wi-Fi code
  (BE200 firmware core max 107, a monitor min_def bandwidth fix) and skips Armbian's out-of-tree
  Realtek drivers ("all out-of-tree drivers broke — again"), which this image does not use.
- Ship `edge` unless a 7.3-only fix is needed; use `bleedingedge` to bisect a 7.2 regression or
  when the user asks for 7.3 (they did, 2026-09-02). Both work with this repo; only
  `bleedingedge` needs the extension's boot glue, and it is already there.
- `current` (6.18) is refused by `build.sh` and the extension: its iwlwifi accepts BE200 firmware
  up to core 99, which no longer exists.

## Phase 0 — read before touching anything (no hardware, ~10 min)

- `reference/why-it-is-hard.md` — what is upstream, what is Armbian-only, what is nowhere.
- `reference/armbian-mechanics.md` — hook names, config semantics, patch dirs, pins.
- `reference/build-history.md` — the six attempts behind the first image and what each one taught.
- In the Armbian checkout (`build/` after one `build.sh` run, or `gh api` on `armbian/build` at
  the pinned commit): re-read `config/boards/nanopi-zero2.csc` and confirm its hooks still match
  `current | edge` only; `grep -rn post_install_kernel_debs lib/`, `pre_umount_final_image`,
  `add_host_dependencies` to confirm the three hook points the extension relies on still exist.
- `git ls-remote --tags https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git`
  and confirm the pinned tag (`WIFI7_FIRMWARE_REF` in `userpatches/extensions/wifi7-mainline.sh`)
  still exists; if bumping it, check the BE200 core range the target kernel accepts
  (`drivers/net/wireless/intel/iwlwifi/cfg/bz.c`, `IWL_BZ_UCODE_CORE_MAX` / `API_MIN`).
- If Armbian's pin is moved: re-verify that `patch/kernel/archive/rockchip64-<ver>/` still has
  `board-nanopi-zero2-enable-pcie.patch`, `rk3528-14-…phy-reset`, `rk3528-13-…otg-timer` and
  `rk3528-pmdomain-rockchip-fixes-for-working-usb-rk3528.patch`. The pmdomain pair is what
  stops 7.2+ from taking a synchronous external abort at boot with USB enabled.

## Phase 1 — repo changes (this Mac)

All of this is already in place on branch `mainline-7.3`; when repeating for a new pin or card:

1. `build.sh`: per-branch `ARMBIAN_TAG` + `ARMBIAN_SHA` (the SHA is what is checked out),
   per-branch `EXTENSIONS`, `WC_IGNORE_CACHE` passthrough, images archived not deleted.
2. `userpatches/extensions/wifi7-mainline.sh`: config symbols in `custom_kernel_config__`,
   firmware copy in `post_install_kernel_debs__500`, verification in `post_install_kernel_debs__900`
   (`${SDCARD}`) and `pre_umount_final_image__950` (`${MOUNT}`).
3. Overlay: `Name=end*` in `10-ethernet.network`; `usb-gadget` + udev rebind rule; avahi
   `ver=` in step with `IMAGE_VERSION`.
4. Lint: `bash -n` and `shellcheck -S warning -e SC2154,SC2034` on every shell file.
5. Unit-test the hooks against a fake image tree: `bash tests/wifi7-mainline-hooks.sh` (runs on
   macOS bash 3 and Linux bash 5). Every "FAILS when…" case must fail; watch a new check fail
   before trusting it.
6. Commit with the fork's attribution; push `mainline-7.3` to remote `fork`.

## Phase 2 — build (HUMAN: the NUC)

- Reachability: `ssh -o BatchMode=yes kevin@10.80.1.17 hostname`. From the office network the
  NUC does not answer; wait for the lab network.
- On the NUC, in `~/nanopi-fork/sensor`: `git branch backup/nuc-$(git rev-parse --short HEAD)`
  first (the checkout there has carried unpushed commits before), then `git fetch fork` and
  `git checkout mainline-7.3`.
- Preflight: `df -h ~` (a mainline kernel worktree plus a fresh Armbian trunk checkout is
  ~10 GB; the Armbian cache is ~22 GB), `du -sh build/cache build/output`.
- First mainline build: `WC_BRANCH=<branch> WC_IGNORE_CACHE=yes ./build.sh 2>&1 | tee ~/build-<branch>-$(date +%F).log`
  inside `tmux`. Budget 1.5–2 h. Later builds: omit `WC_IGNORE_CACHE`.
- Expected noise: `BRANCH_VALID_FOR_BOARD=no` for `bleedingedge` (the board file lists
  `vendor,current,edge`); the extension supplies what the board file would. Not expected: any
  `wifi7-mainline verify FAILED` line — that is the build telling you which silent failure it
  caught; fix the cause, do not relax the check.
- In the log, confirm these applied: `board-nanopi-zero2-enable-pcie.patch`,
  `rk3528-13-…`, `rk3528-14-…`, `rk3528-pmdomain-rockchip-fixes-for-working-usb-rk3528.patch`.

## Phase 3 — offline image check (HUMAN: the NUC, no board)

`checklists/offline-image-check.md`. Mount the image with `losetup -P`, re-run the verify items
by hand, and run `dumpimage -l` on the U-Boot `u-boot.itb` (a cached edge artifact once shipped a
0-byte FDT: armbian/build#9508). Do not flash an image that fails this.

## Phase 4 — hardware bring-up (HUMAN: board, SD card, serial adapter, test window)

`checklists/hardware-bringup.md`. Order matters: collect the vendor **before** column on the
old card first (it has never been captured), then serial console before network, then Ethernet,
gadget, PCIe/BE200, Wi-Fi 7 capture, temperature. The vendor SD card stays intact and is the
rollback (`checklists/rollback.md`).

## Phase 5 — adding a Wi-Fi card later

`reference/wifi7-cards.md` has the per-chipset table and the recipe: config symbol via
`opts_m` in the extension, firmware source (armbian-firmware already has mt7925 and WCN7850;
BE200 and RTL8922A come from the pinned linux-firmware tag; Debian `firmware-*` packages collide
with `armbian-firmware`), a verify-hook line, and the width limit to record for WLAN Commander.
Physical limits on this board: one USB 2.0 host port (480 Mbit/s ceiling for any USB stick), a
PCIe 2.1 x1 M.2 Key-E slot, 3.3 V shared rail. No USB Wi-Fi 7 stick captures 320 MHz.

## What "done" means

- Build passes with both verify hooks green; `.build-info` records fork commit, Armbian commit,
  branch, firmware tag.
- Offline check passes, including a non-zero FDT in `u-boot.itb`.
- On hardware: serial console at 1500000 on `ttyS0`; `end0` up at 1000/Full; `usb0` NCM on the
  USB-C link; `lspci` shows `8086:272b`; `dmesg` shows `iwlmld` op-mode and `loaded firmware …
  c10x`; no `No config found for PCI dev`, no `synchronous external abort`; `iw list` shows EHT
  and 320 MHz; WLAN Commander discovers `wlanpi-nano-<serial>` and completes a 6 GHz 320 MHz
  capture; case temperature under a 10-minute capture recorded (mainline has no thermal zone).
- Memory/notes updated with anything that disproved a line in `reference/`.
