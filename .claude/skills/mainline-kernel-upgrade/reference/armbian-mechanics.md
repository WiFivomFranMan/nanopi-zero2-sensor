# Armbian build mechanics this repo depends on

Verified at `v26.5.1` (`8de11a01`) and `v26.11.0-trunk.30` (`ee00ac7c8`) on 2026-09-02; the fork's mainline pin is `main` at `6d07521a` (2026-09-02), the first commit with both the 7.2/7.3 mapping and the `rockchip64-7.3` patch archive. File
paths are inside the Armbian checkout (`build/`).

## Branch → kernel → names

For `BOARD=nanopi-zero2` (`BOARDFAMILY=rk35xx`, which sources
`config/sources/families/include/rockchip64_common.inc`):

| BRANCH | LINUXFAMILY | KERNEL_MAJOR_MINOR (trunk.30) | KERNELSOURCE / KERNELBRANCH | KERNELPATCHDIR | LINUXCONFIG | kernel deb |
|---|---|---|---|---|---|---|
| vendor | rk35xx | 6.1 | `armbian/linux-rockchip` `rk-6.1-rkr5.1` | `rk35xx-vendor-6.1` | `linux-rk35xx-vendor` | `linux-image-vendor-rk35xx` |
| current | rockchip64 | 6.18 | kernel.org stable `branch:linux-6.18.y` | `archive/rockchip64-6.18` | `linux-rockchip64-current` | `linux-image-current-rockchip64` |
| edge | rockchip64 | 7.2 | kernel.org stable `branch:linux-7.2.y` (rolling) | `archive/rockchip64-7.2` | `linux-rockchip64-edge` | `linux-image-edge-rockchip64` |
| bleedingedge | rockchip64 | 7.3 | torvalds `tag:v7.3-rc1` (fixed) | `archive/rockchip64-7.3` | `linux-rockchip64-bleedingedge` | `linux-image-bleedingedge-rockchip64` |

At `v26.5.1` edge was 7.0 and bleedingedge 7.1. `MAINLINE_MIRROR`/`REGIONAL_MIRROR=china`
silently redirect `KERNELSOURCE` to a mirror (`lib/functions/configuration/main-config.sh`).
`KERNEL_MAJOR_MINOR` set from the command line is reset by `common_defaults_for_mainline`.

U-Boot for the rk35xx family is Radxa's vendor tree on **every** branch:
`BOOTSOURCE=https://github.com/radxa/u-boot.git`, `BOOTBRANCH=branch:next-dev-v2024.10`,
`BOOTCONFIG=hinlink_rk3528_defconfig` (its default DT is the HINLINK H28K), `BOOT_SCENARIO=spl-blobs`
(rkbin `rk3528_ddr_1056MHz_v1.09.bin` + `rk3528_bl31_v1.17.elf`, mainline SPL packed by
`mkimage -T rksd`). The deb version string is `2017.09` because that Makefile still says so.
Mainline U-Boot v2026.07 has `nanopi-zero2-rk3528_defconfig`; the only Armbian RK3528 board
using it is the Radxa E24C (see its board file for the override pattern). Not used here.

## Kernel config: full replacement vs hooks

`lib/functions/compilation/kernel-config.sh`: `prepare_kernel_config_core_or_userpatches()`
picks `userpatches/${LINUXCONFIG}.config` if present, else `config/kernel/${LINUXCONFIG}.config`,
and `kernel_config_initialize()` **copies it wholesale to `.config`**, then runs the config
hooks, then `make olddefconfig`. So:

- A userpatches config file is a full replacement. The fork's `linux-rk35xx-vendor.config` is
  Armbian's vendor config plus 4 lines; it is only consulted when `LINUXCONFIG` matches.
- Small overrides belong in a `custom_kernel_config__<name>()` hook using the arrays
  `opts_y`, `opts_m`, `opts_n`, `opts_val` (applied by `armbian_kernel_config_apply_opts_from_arrays`
  in `armbian-kernel.sh`), or `kernel_config_set_{y,m,n,string,val}`. **The hooks run twice**,
  once for version hashing with no `.config` present — the arrays are safe; direct
  `kernel_config_set_*` calls must be guarded with `[[ -f .config ]]`.
- `olddefconfig` drops symbols that do not exist or whose dependencies are unmet, silently. With
  `KERNEL_CONFIGURE=no` nobody sees it. Grep the installed `/boot/config-*` afterwards (the
  extension does).
- Armbian core already forces `CFG80211=m MAC80211=m MAC80211_MESH=y CFG80211_WEXT=y` on
  kernels ≥ 6.13.

Mainline configs at trunk.30 (`config/kernel/linux-rockchip64-bleedingedge.config`) carry
`IWLWIFI=m IWLDVM=m IWLMVM=m` (no `IWLMLD`), `MT7925E/U=m`, `ATH12K=m`, `RTW89=m` + `8922AE`
(no `8922AU` line), `PCIE_ROCKCHIP_DW_HOST=y`, `PHY_ROCKCHIP_NANENG_COMBO_PHY=y`,
`PHY_ROCKCHIP_INNO_USB2=y`, `USB_DWC3=y`, `USB_GADGET=y`, `USB_CONFIGFS=m`, `USB_CONFIGFS_NCM=y`,
`DW_WATCHDOG=y`, `ROCKCHIP_THERMAL=y` (no rk3528 sensor to drive), no `MOTORCOMM_PHY`, no
`REALTEK_PHY`, no `PCI_MSI` line.

## Extension hook points used by `wifi7-mainline.sh`

| Hook | Where called | Variables | Used for |
|---|---|---|---|
| `extension_prepare_config__` | early config | `BRANCH`, `BOARD` | refuse vendor/current; pin firmware ref |
| `add_host_dependencies__` | `lib/functions/host/prepare-host.sh` | `EXTRA_BUILD_DEPS+=()` | `device-tree-compiler` |
| `post_family_config__` then `post_family_config_branch_<branch>__` | `lib/functions/configuration/main-config.sh` | `BOOT_FDT_FILE`, `SERIALCON` | the per-branch form runs after every plain one: bleedingedge DTB/console |
| `extension_finish_config__` | end of config | all config vars | assert DTB/console outcome |
| `custom_kernel_config__` | `kernel_config_initialize()` (twice) | `opts_*` | config symbols |
| `post_family_tweaks__` | rootfs stage, `${SDCARD}` mounted with `/boot/boot.cmd` | `${SDCARD}` | boot.cmd console + `mkimage` |
| `post_install_kernel_debs__` | `lib/functions/rootfs/distro-agnostic.sh`, after kernel/u-boot/headers debs, before BSP | `${SDCARD}`, `${SRC}` | firmware copy; verification |
| `pre_umount_final_image__` | `lib/functions/image/rootfs-to-image.sh`, before unmounting `/` and `/boot` of the final image | `${MOUNT}` | `armbianEnv.txt` / `boot.cmd` / `boot.scr` checks |

Hook implementations sort alphabetically by the part after `__`; numeric prefixes are a
convention, not a guarantee of ordering against Armbian's own implementations.
`exit_with_error "title" "detail"` aborts the build; `display_alert "a" "b" "info|wrn|err"` logs.

## `fetch_from_repo <url> <dir> <ref> <ref_subdir>`

`lib/functions/general/git.sh`. `<ref>` is `branch:x`, `tag:y`, `commit:z` or `head`. With
`<ref_subdir>=no` the checkout lives at `${SRC}/cache/sources/<dir>`; with `yes` at
`<dir>/<ref_name>`. GitHub URLs are rewritten through `GITHUB_SOURCE`; kernel.org URLs are not.

## Patches

Mainline kernel patches go in `patch/kernel/archive/rockchip64-<MAJOR.MINOR>/` (no `series`;
alphabetical). **A same-named file in `userpatches/kernel/…` does NOT override the core one**:
`patching.py` builds `CONST_PATCH_ROOT_DIRS` user-then-core per directory and fills a dict keyed
by file name, so the core file wins (verified by a build on 2026-09-02). The fork's extension
provides the missing mechanism: files under `userpatches/kernel-overrides/<KERNELPATCHDIR>/`
are copied over the core file at `extension_finish_config__`, before the patch dir is hashed.
**A failed regular patch is fatal** on
current main (`patching.py` raises after the summary); an empty override file is also fatal
("No valid patches found"), so to neutralise a broken core patch ship a same-named override
that applies. Case in point (2026-09-02): `board-orangepi-5-es8388-route-mclk-to-io.patch`
failed on 7.3-rc1 because Armbian's fix replaced the hunk's tabs with spaces. RK3528-relevant files at trunk.30 for 7.2 and 7.3
(identical sets): `board-nanopi-zero2-enable-pcie.patch`, `rk3528-02-…Add-SFC-node`,
`rk3528-13-phy-rockchip-inno-usb2-fix-otg-timer-cleanup`,
`rk3528-14-…nanopi-zero2-fix-ethernet-phy-reset`, `rk3528-net-dsa-realtek-fixes-for-radxa-e24c`,
`rk3528-net-dwmac-rk-rgmii-delays-wip.patch.disabled`,
`rk3528-pmdomain-rockchip-fixes-for-working-usb-rk3528.patch`. The 6.18 set additionally
carries the USB nodes and Zero2 USB enable that went upstream in 7.2. **A missing archive
directory is silent**: Armbian logs `Using kernel patch dir: archive/rockchip64-7.3` and applies
nothing if the directory does not exist (trunk.30 had 6.12/6.18/7.1/7.2 only).

## The out-of-tree driver harness (`EXTRAWIFI`)

`EXTRAWIFI` defaults to `yes` (`lib/functions/configuration/main-config.sh`) and makes
`drivers-harness.sh` inject a dozen out-of-tree Wi-Fi drivers into the kernel tree before the
compile, each behind a `linux-version compare` gate in `drivers_network.sh`. Several have no
upper bound and fail on 7.3. `EXTRAWIFI=no` skips the whole harness (and its patch hash);
`KERNEL_DRIVERS_SKIP+=(driver_<name>)` skips one. The kernel artifact hash includes both.

## Artifacts and caches

`ARTIFACT_IGNORE_CACHE=yes` (a `compile.sh` parameter) bypasses the local and OCI artifact
cache for **everything**, kernel included — so the first build is a full compile. Kernel
artifacts already re-key on `opts_*` changes via `kernel_config_modifying_hashes`; U-Boot does
not re-key on the board's cached artifact having been built wrong (#9508), hence the bypass on
the first build and the `dumpimage -l` gate afterwards.

`INSTALL_HEADERS=yes` only controls installing the headers deb into the image (the deb is
built regardless); the mainline image does not need it (all drivers in-tree).

`INCLUDE_HOME_DIR=yes` is still required on trunk.30 (`rootfs-to-image.sh` excludes `/home/*`
otherwise).

## Images

Output: `build/output/images/Armbian-unofficial_<ver>_Nanopi-zero2_trixie_<branch>_<kver>_minimal.img`
renamed by `build.sh`. DTBs in the image: `/boot/dtb-<kver>/rockchip/*.dtb` (`/boot/dtb` is a
symlink made later). Kernel config: `/boot/config-<kver>`. `armbianEnv.txt` carries `fdtfile=`;
`boot.cmd`/`boot.scr` carry the console. The U-Boot deb `linux-u-boot-nanopi-zero2-<branch>`
ships `/usr/lib/linux-u-boot-…/idbloader.img` and `u-boot.itb`.
