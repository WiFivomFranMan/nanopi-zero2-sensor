#!/usr/bin/env bash
#
# Wi-Fi 7 sensor support on a MAINLINE kernel (Armbian edge = 7.2.y, bleedingedge = 7.3-rc).
# Enable with: ENABLE_EXTENSIONS=wifi7-mainline   (build.sh does this for non-vendor branches)
#
# What this replaces: on the vendor 6.1 kernel the BE200 only worked through Intel's
# out-of-tree backport-iwlwifi (extensions/iwlwifi-backport.sh). On 7.x the driver is in-tree
# (iwlwifi + the iwlmld op-mode), so nothing is compiled here. What is still missing from a
# stock Armbian mainline image, and what each hook below supplies:
#
#   1. CONFIG_IWLMLD. No Armbian rockchip64 config sets it and it has no Kconfig default.
#      Without it the BE200's device table is compiled out entirely and the card fails to
#      probe with "No config found for PCI dev 272b/..." -- it does NOT fall back to iwlmvm.
#   2. BE200 firmware. armbian-firmware ships none; Debian trixie's firmware-iwlwifi stops at
#      API 97 while 7.2 needs core files c102..c106 (7.3: c102..c107). Fetched from linux-firmware.
#   3. bleedingedge boot glue. The board file (config/boards/nanopi-zero2.csc) only switches the
#      DTB to rk3528-nanopi-zero2.dtb and the console to ttyS0 for BRANCH current|edge; on
#      bleedingedge it would boot with the vendor DTB name and no serial console.
#   4. Loud verification. The M.2 slot exists on mainline only through Armbian's out-of-tree
#      board-nanopi-zero2-enable-pcie.patch, and a patch that fails to apply is a *warning* in
#      Armbian. Every silent-failure mode above is turned into a build failure here.

function extension_prepare_config__wifi7_mainline() {
	case "${BRANCH}" in
		vendor)
			exit_with_error "wifi7-mainline does not apply to BRANCH=vendor" "use ENABLE_EXTENSIONS=iwlwifi-backport for the 6.1 vendor kernel"
			;;
		current)
			exit_with_error "wifi7-mainline refuses BRANCH=current (6.18)" "its iwlwifi accepts BE200 firmware up to core 99 only; no such file exists any more"
			;;
	esac
	# kernel.org linux-firmware, pinned to a dated tag for reproducible images. Tag 20260810
	# carries iwlwifi-gl-c0-fm-c0-c101/c102/c103/c106.ucode + .pnvm (BE200), mediatek/mt7925/*,
	# ath12k/WCN7850/hw2.0/{,ncm865/} and rtw89/rtw8922a_fw*.bin. Intel's iwlwifi/linux-firmware
	# fork has no dated tags, so it cannot be used with a tag: ref.
	WIFI7_FIRMWARE_REPOSITORY="${WIFI7_FIRMWARE_REPOSITORY:-https://git.kernel.org/pub/scm/linux/kernel/git/firmware/linux-firmware.git}"
	WIFI7_FIRMWARE_REF="${WIFI7_FIRMWARE_REF:-20260810}"
	display_alert "Wi-Fi 7 mainline support enabled" "BRANCH=${BRANCH}, firmware tag ${WIFI7_FIRMWARE_REF}" "info"
}

# dtc is needed by the verify hook to prove the PCIe node is enabled in the built DTB.
function add_host_dependencies__wifi7_mainline() {
	EXTRA_BUILD_DEPS+=("device-tree-compiler")
}

# --- 3. bleedingedge boot glue -------------------------------------------------------------
# Mirrors post_family_config__nanopi_zero2_mainline / post_family_tweaks__nanopi_zero2_serial_console
# in config/boards/nanopi-zero2.csc, which match `current | edge)` only. The per-branch hook
# below is called by Armbian *after* every plain post_family_config hook, so ordering against
# the board file is guaranteed rather than alphabetical.
function post_family_config_branch_bleedingedge__nanopi_zero2_mainline_dtb() {
	[[ "${BOARD}" == "nanopi-zero2" ]] || return 0
	declare -g BOOT_FDT_FILE="rockchip/rk3528-nanopi-zero2.dtb"
	declare -g SERIALCON="ttyS0"
	display_alert "${BOARD}" "Using ${BOOT_FDT_FILE} and SERIALCON=${SERIALCON} for ${BRANCH} (wifi7-mainline)" "info"
}

function post_family_tweaks__nanopi_zero2_zz_serial_console_bleedingedge() {
	[[ "${BOARD}" == "nanopi-zero2" && "${BRANCH}" == "bleedingedge" ]] || return 0
	display_alert "${BOARD}" "Adjusting boot.cmd serial console to ttyS0 for ${BRANCH} (wifi7-mainline)" "info"
	sed -i 's/console=ttyS2,1500000/console=ttyS0,1500000/g' "${SDCARD}"/boot/boot.cmd
	mkimage -C none -A arm -T script -d "${SDCARD}"/boot/boot.cmd "${SDCARD}"/boot/boot.scr
}

# Assert the outcome regardless of which hook produced it. Runs at the very end of config.
function extension_finish_config__wifi7_mainline_assert_boot_glue() {
	[[ "${BOARD}" == "nanopi-zero2" ]] || return 0
	[[ "${BOOT_FDT_FILE}" == "rockchip/rk3528-nanopi-zero2.dtb" ]] ||
		exit_with_error "BOOT_FDT_FILE is '${BOOT_FDT_FILE}'" "expected rockchip/rk3528-nanopi-zero2.dtb on ${BRANCH}; the vendor DTB name does not exist on mainline and the board would not boot"
	[[ "${SERIALCON}" == "ttyS0" ]] ||
		exit_with_error "SERIALCON is '${SERIALCON}'" "expected ttyS0 on ${BRANCH}; RK3528's debug UART is UART0 on mainline"
}

# --- 3b. replacing broken core kernel patches --------------------------------------------
# Armbian's patcher (lib/tools/patching.py) keys patch files by name and iterates the CORE root
# last, so a same-named file under userpatches/kernel/ is silently shadowed by the core one
# (verified 2026-09-02; the opposite of what one would expect). There is no skip list, an empty
# file is fatal, and a failed regular patch is fatal. So: files placed under
# userpatches/kernel-overrides/<KERNELPATCHDIR>/ are copied OVER the core file of the same name
# here, at the end of config -- before the patch directory is hashed for the kernel artifact.
# The Armbian tree is force-checked-out by build.sh on every run, so this never accumulates.
function extension_finish_config__wifi7_mainline_core_patch_overrides() {
	local dir="${USERPATCHES_PATH}/kernel-overrides/${KERNELPATCHDIR}"
	[[ -d "${dir}" ]] || return 0
	local f name target
	for f in "${dir}"/*.patch; do
		[[ -f "${f}" ]] || continue
		name="${f##*/}"
		target="${SRC}/patch/kernel/${KERNELPATCHDIR}/${name}"
		if [[ -f "${target}" ]] && cmp -s "${f}" "${target}"; then
			display_alert "Core kernel patch already matches fork override" "${KERNELPATCHDIR}/${name}" "info"
			continue
		fi
		[[ -f "${target}" ]] || display_alert "Fork override has no core counterpart (will be applied as a new patch)" "${KERNELPATCHDIR}/${name}" "wrn"
		display_alert "Replacing core kernel patch with fork override" "${KERNELPATCHDIR}/${name}" "wrn"
		cp -f "${f}" "${target}"
	done
}

# --- 1. kernel config --------------------------------------------------------------------
# opts_* arrays only: Armbian calls kernel-config hooks twice (once for version hashing with no
# .config present), and the arrays are applied before `make olddefconfig`. A symbol that does not
# exist in the target kernel is dropped silently by olddefconfig, which is why the verify hook
# below greps the *resulting* config for every one of these.
function custom_kernel_config__wifi7_mainline() {
	# Intel BE200 / BE20x: the MLD op-mode. Keep IWLMVM (Armbian already sets it) for older parts.
	opts_m+=("IWLMLD")
	# MediaTek MT7925 (PCIe + USB; Netgear A9000/A8500 sticks). 160 MHz max on this chip.
	opts_m+=("MT7925E" "MT7925U")
	# Qualcomm WCN7850 / QCNCM865 (PCIe only). Monitor mode since 6.16.
	opts_m+=("ATH12K")
	# Realtek Wi-Fi 7 (8922AE PCIe, 8922AU USB e.g. TP-Link TBE400UH) and older USB rtw89 parts.
	opts_m+=("RTW89" "RTW89_8922AE" "RTW89_8922AU" "RTW89_8851BU" "RTW89_8852AU" "RTW89_8852BU" "RTW89_8852CU")
	# Ethernet PHY: identity on the Zero2 is disputed (RTL8211F vs Motorcomm YT8531S) and Armbian's
	# config rewrite dropped MOTORCOMM_PHY in May 2026. Build both in.
	opts_y+=("MOTORCOMM_PHY" "REALTEK_PHY")
	# The M.2 slot and the USB-C NCM gadget. Armbian's configs already carry most of these; forcing
	# them here means the verify hook's expectations are stated in one place.
	opts_y+=("PCI_MSI" "PCIE_ROCKCHIP_DW_HOST" "PHY_ROCKCHIP_NANENG_COMBO_PHY" "PHY_ROCKCHIP_INNO_USB2")
	opts_y+=("USB_DWC3" "USB_GADGET" "USB_CONFIGFS_NCM")
	opts_m+=("USB_CONFIGFS")
}

# --- 2. firmware -------------------------------------------------------------------------
function post_install_kernel_debs__500_wifi7_firmware() {
	[[ -d "${SDCARD}" ]] || exit_with_error "Target root filesystem is unavailable" "SDCARD=${SDCARD:-unset}"
	display_alert "Fetching linux-firmware (cached)" "tag ${WIFI7_FIRMWARE_REF}" "info"
	# 4th arg "no": no per-ref subdirectory, so the checkout lives at ${SRC}/cache/sources/linux-firmware
	fetch_from_repo "${WIFI7_FIRMWARE_REPOSITORY}" "linux-firmware" "tag:${WIFI7_FIRMWARE_REF}" "no"
	local fw_src="${SRC}/cache/sources/linux-firmware"
	local fw_dst="${SDCARD}/lib/firmware"
	mkdir -p "${fw_dst}/rtw89"

	# Intel BE200 (gl-c0-fm-c0): core-named ucode files only -- the 7.x loader never tries the
	# API-numbered ones -- plus the PNVM. Since 2026 linux-firmware keeps them under
	# intel/iwlwifi/ with WHENCE "Link:" entries that `make install` turns into the top-level
	# names the driver requests; older trees had them at the top level. Copy the real files to
	# the top level of /lib/firmware, which is where iwlwifi looks. armbian-firmware provides
	# mt7925 and WCN7850 already.
	local intel_src="${fw_src}"
	[[ -d "${fw_src}/intel/iwlwifi" ]] && intel_src="${fw_src}/intel/iwlwifi"
	local count
	count="$(find "${intel_src}" -maxdepth 1 -type f -name 'iwlwifi-gl-c0-fm-c0-c*.ucode' | wc -l | tr -d ' ')"
	(( count > 0 )) || exit_with_error "No BE200 core firmware in linux-firmware ${WIFI7_FIRMWARE_REF}" "expected iwlwifi-gl-c0-fm-c0-c1xx.ucode under ${intel_src}"
	find "${intel_src}" -maxdepth 1 -type f -name 'iwlwifi-gl-c0-fm-c0-c*.ucode' -exec cp -av {} "${fw_dst}/" \;
	if [[ -f "${intel_src}/iwlwifi-gl-c0-fm-c0.pnvm" ]]; then
		cp -av "${intel_src}/iwlwifi-gl-c0-fm-c0.pnvm" "${fw_dst}/"
	else
		exit_with_error "iwlwifi-gl-c0-fm-c0.pnvm missing from linux-firmware ${WIFI7_FIRMWARE_REF}" "the BE200 needs the PNVM alongside the ucode (looked in ${intel_src})"
	fi

	# Realtek RTL8922A(E/U): armbian-firmware has no 8922a files and Conflicts with Debian's
	# firmware-realtek, so this is the only route on an Armbian image.
	count="$(find "${fw_src}/rtw89" -maxdepth 1 -type f -name 'rtw8922a_fw*.bin' 2> /dev/null | wc -l | tr -d ' ')"
	if (( count > 0 )); then
		find "${fw_src}/rtw89" -maxdepth 1 -type f -name 'rtw8922a_fw*.bin' -exec cp -av {} "${fw_dst}/rtw89/" \;
	else
		display_alert "No rtw8922a firmware in linux-firmware ${WIFI7_FIRMWARE_REF}" "RTL8922AU sticks will not work" "wrn"
	fi
}

# --- 4. verification: fail the build, never warn ------------------------------------------
function post_install_kernel_debs__900_wifi7_verify() {
	[[ -d "${SDCARD}" ]] || exit_with_error "Target root filesystem is unavailable" "SDCARD=${SDCARD:-unset}"
	local -a failures=()

	# Kernel config as installed in the image.
	local cfg
	cfg="$(compgen -G "${SDCARD}/boot/config-*" | head -n1 || true)"
	[[ -n "${cfg}" ]] || exit_with_error "No /boot/config-* in the image" "did the kernel deb install?"
	local kver="${cfg##*/config-}"
	[[ "${kver}" == 7.* ]] || failures+=("kernel is ${kver}, expected 7.x")
	local sym
	for sym in \
		CONFIG_IWLWIFI=m CONFIG_IWLMLD=m \
		CONFIG_MT7925E=m CONFIG_MT7925U=m CONFIG_ATH12K=m \
		CONFIG_RTW89=m CONFIG_RTW89_8922AE=m CONFIG_RTW89_8922AU=m \
		CONFIG_MOTORCOMM_PHY=y CONFIG_REALTEK_PHY=y \
		CONFIG_PCI_MSI=y CONFIG_PCIE_ROCKCHIP_DW_HOST=y \
		CONFIG_PHY_ROCKCHIP_NANENG_COMBO_PHY=y CONFIG_PHY_ROCKCHIP_INNO_USB2=y \
		CONFIG_USB_DWC3=y CONFIG_USB_GADGET=y CONFIG_USB_CONFIGFS=m CONFIG_USB_CONFIGFS_NCM=y \
		CONFIG_CFG80211=m CONFIG_MAC80211=m; do
		grep -qx "${sym}" "${cfg}" || failures+=("${sym} missing from ${cfg##*/}")
	done

	# The module that actually drives the BE200.
	compgen -G "${SDCARD}/lib/modules/${kver}/kernel/drivers/net/wireless/intel/iwlwifi/mld/iwlmld.ko*" > /dev/null ||
		failures+=("iwlmld.ko not installed for ${kver}")

	# BE200 firmware inside the range the 7.2/7.3 loader will try (c102..c106 satisfies both).
	local have_fw=no n
	for n in 102 103 104 105 106; do
		[[ -f "${SDCARD}/lib/firmware/iwlwifi-gl-c0-fm-c0-c${n}.ucode" ]] && have_fw=yes
	done
	[[ "${have_fw}" == yes ]] || failures+=("no iwlwifi-gl-c0-fm-c0-c102..c106.ucode in /lib/firmware")
	[[ -f "${SDCARD}/lib/firmware/iwlwifi-gl-c0-fm-c0.pnvm" ]] || failures+=("iwlwifi-gl-c0-fm-c0.pnvm missing")

	# The DTB, and inside it the PCIe controller enabled. Only Armbian's out-of-tree
	# board-nanopi-zero2-enable-pcie.patch does that; upstream never has. Decompile with dtc --
	# `strings`/grep on the blob cannot tell "okay" from "disabled" (both are plain strings).
	if [[ "${BOARD}" == "nanopi-zero2" ]]; then
		local dtb
		dtb="$(compgen -G "${SDCARD}/boot/dtb*/rockchip/rk3528-nanopi-zero2.dtb" | head -n1 || true)"
		if [[ -z "${dtb}" ]]; then
			failures+=("rk3528-nanopi-zero2.dtb not in the image (looked under /boot/dtb*/rockchip/)")
		elif ! command -v dtc > /dev/null; then
			failures+=("dtc not available on the host; cannot prove the PCIe node is enabled")
		else
			local pcie_status
			pcie_status="$(dtc -I dtb -O dts -q "${dtb}" 2> /dev/null | awk '
				/pcie@fe000000 \{/ { inside = 1; depth = 0 }
				inside {
					n = gsub(/\{/, "{"); depth += n
					n = gsub(/\}/, "}"); depth -= n
					if ($0 ~ /^[[:space:]]*status[[:space:]]*=/ && depth == 1) { print $0; exit }
					if (depth <= 0 && $0 ~ /\}/) { exit }
				}')"
			[[ "${pcie_status}" == *'"okay"'* ]] ||
				failures+=("pcie@fe000000 is not enabled in ${dtb##*/} (status: ${pcie_status:-absent}); board-nanopi-zero2-enable-pcie.patch did not apply -- the M.2 slot would be dead")
		fi
	fi

	if (( ${#failures[@]} > 0 )); then
		local f
		for f in "${failures[@]}"; do display_alert "wifi7-mainline verify FAILED" "${f}" "err"; done
		exit_with_error "wifi7-mainline verification failed" "${#failures[@]} problem(s); see above"
	fi
	display_alert "wifi7-mainline verified" "kernel ${kver}: iwlmld, BE200 firmware, PCIe node, gadget config all present" "info"
}

# Boot path as it will actually be read by U-Boot: these decide whether the board boots,
# the DTB's mere presence does not. Runs on the final image (${MOUNT}), after armbianEnv.txt
# and boot.scr have been written.
function pre_umount_final_image__950_wifi7_boot_check() {
	[[ "${BOARD}" == "nanopi-zero2" ]] || return 0
	local -a failures=()
	grep -q '^fdtfile=rockchip/rk3528-nanopi-zero2.dtb' "${MOUNT}/boot/armbianEnv.txt" 2> /dev/null ||
		failures+=("armbianEnv.txt does not select rockchip/rk3528-nanopi-zero2.dtb")
	grep -q 'console=ttyS0,1500000' "${MOUNT}/boot/boot.cmd" 2> /dev/null ||
		failures+=("boot.cmd does not set console=ttyS0,1500000")
	[[ -f "${MOUNT}/boot/boot.scr" ]] || failures+=("boot.scr missing")
	if (( ${#failures[@]} > 0 )); then
		local f
		for f in "${failures[@]}"; do display_alert "wifi7-mainline boot check FAILED" "${f}" "err"; done
		exit_with_error "wifi7-mainline boot check failed" "the image would not boot or would boot silently"
	fi
	display_alert "wifi7-mainline boot check passed" "fdtfile + console=ttyS0 + boot.scr" "info"
}
