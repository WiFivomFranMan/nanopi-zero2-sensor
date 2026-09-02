#!/usr/bin/env bash
# Unit test for the wifi7-mainline extension hooks against a fake image tree. Needs dtc.
# Runs on macOS bash 3 and Linux bash 5:  bash tests/wifi7-mainline-hooks.sh
set -u
EXT="$(cd "$(dirname "$0")/.." && pwd)/userpatches/extensions/wifi7-mainline.sh"
T="$(mktemp -d)"; trap 'rm -rf "$T"' EXIT
KVER=7.3.0-rc1-bleedingedge-rockchip64

mk_tree() {   # builds a passing tree at $1
  local R=$1; rm -rf "$R"; mkdir -p "$R/sdcard/boot/dtb-$KVER/rockchip" "$R/sdcard/lib/modules/$KVER/kernel/drivers/net/wireless/intel/iwlwifi/mld" "$R/sdcard/lib/firmware/rtw89" "$R/mount/boot"
  for s in CONFIG_IWLWIFI=m CONFIG_IWLMLD=m CONFIG_MT7925E=m CONFIG_MT7925U=m CONFIG_ATH12K=m CONFIG_RTW89=m CONFIG_RTW89_8922AE=m CONFIG_RTW89_8922AU=m CONFIG_MOTORCOMM_PHY=y CONFIG_REALTEK_PHY=y CONFIG_PCI_MSI=y CONFIG_PCIE_ROCKCHIP_DW_HOST=y CONFIG_PHY_ROCKCHIP_NANENG_COMBO_PHY=y CONFIG_PHY_ROCKCHIP_INNO_USB2=y CONFIG_USB_DWC3=y CONFIG_USB_GADGET=y CONFIG_USB_CONFIGFS=m CONFIG_USB_CONFIGFS_NCM=y CONFIG_CFG80211=m CONFIG_MAC80211=m CONFIG_IWLMVM=m; do echo "$s"; done > "$R/sdcard/boot/config-$KVER"
  : > "$R/sdcard/lib/modules/$KVER/kernel/drivers/net/wireless/intel/iwlwifi/mld/iwlmld.ko.xz"
  : > "$R/sdcard/lib/firmware/iwlwifi-gl-c0-fm-c0-c106.ucode"; : > "$R/sdcard/lib/firmware/iwlwifi-gl-c0-fm-c0.pnvm"
  cat > "$R/pcie.dts" <<'DTS'
/dts-v1/;
/ {
	compatible = "friendlyarm,nanopi-zero2", "rockchip,rk3528";
	soc {
		#address-cells = <2>; #size-cells = <2>;
		pcie: pcie@fe000000 {
			compatible = "rockchip,rk3528-pcie", "rockchip,rk3568-pcie";
			reg = <0x0 0xfe000000 0x0 0x400000>;
			status = "STATUS_HERE";
			pcie_intc: legacy-interrupt-controller {
				interrupt-controller;
				status = "disabled";
			};
		};
		other: usb@fe500000 { status = "okay"; };
	};
};
DTS
  echo 'fdtfile=rockchip/rk3528-nanopi-zero2.dtb' > "$R/mount/boot/armbianEnv.txt"
  echo 'setenv bootargs "console=ttyS0,1500000 root=UUID=x"' > "$R/mount/boot/boot.cmd"
  : > "$R/mount/boot/boot.scr"
}
mk_dtb() { sed "s/STATUS_HERE/$2/" "$1/pcie.dts" | dtc -I dts -O dtb -q -o "$1/sdcard/boot/dtb-$KVER/rockchip/rk3528-nanopi-zero2.dtb" -; }

run_hooks() {   # $1 tree, $2 which hook; runs in a subshell with stubs; prints PASS/FAIL
  ( set +e
    display_alert() { echo "  [alert:$3] $1 :: $2"; }
    exit_with_error() { echo "  [exit_with_error] $1 :: ${2:-}"; exit 1; }
    fetch_from_repo() { echo "  [fetch_from_repo stub] $*"; }
    SDCARD="$1/sdcard"; MOUNT="$1/mount"; BOARD=nanopi-zero2; BRANCH=bleedingedge; SRC="$1"; KERNEL_MAJOR_MINOR=7.3
    BOOT_FDT_FILE="rockchip/rk3528-nanopi-zero2.dtb"; SERIALCON=ttyS0
    # shellcheck disable=SC1090
    source "$EXT"
    "$2" ) >"$1/log.txt" 2>&1; rc=$?
  return $rc
}
expect() { # $1 desc $2 expected(0/1) $3 tree $4 hook
  run_hooks "$3" "$4"; rc=$?
  if [[ $rc -eq $2 ]]; then echo "ok   : $1 (rc=$rc)"; else echo "FAIL : $1 (rc=$rc, expected $2)"; sed 's/^/       /' "$3/log.txt"; overall=1; fi
}
overall=0
R="$T/t"; 
mk_tree "$R"; mk_dtb "$R" okay
expect "verify passes on a good tree" 0 "$R" post_install_kernel_debs__900_wifi7_verify
expect "boot check passes on a good tree" 0 "$R" pre_umount_final_image__950_wifi7_boot_check
expect "finish_config assertion passes" 0 "$R" extension_finish_config__wifi7_mainline_assert_boot_glue
mk_tree "$R"; mk_dtb "$R" disabled
expect "verify FAILS when pcie status is disabled (child says disabled too)" 1 "$R" post_install_kernel_debs__900_wifi7_verify
mk_tree "$R"; mk_dtb "$R" okay; sed -i.bak '/CONFIG_IWLMLD=m/d' "$R/sdcard/boot/config-$KVER"
expect "verify FAILS when CONFIG_IWLMLD is absent" 1 "$R" post_install_kernel_debs__900_wifi7_verify
mk_tree "$R"; mk_dtb "$R" okay; rm "$R/sdcard/lib/firmware/iwlwifi-gl-c0-fm-c0-c106.ucode"; : > "$R/sdcard/lib/firmware/iwlwifi-gl-c0-fm-c0-c107.ucode"
expect "verify FAILS when only c107 firmware exists (7.2 could not load it)" 1 "$R" post_install_kernel_debs__900_wifi7_verify
mk_tree "$R"; mk_dtb "$R" okay; rm "$R/sdcard/lib/modules/$KVER/kernel/drivers/net/wireless/intel/iwlwifi/mld/iwlmld.ko.xz"
expect "verify FAILS when iwlmld.ko is missing" 1 "$R" post_install_kernel_debs__900_wifi7_verify
mk_tree "$R"; mk_dtb "$R" okay; rm "$R/sdcard/boot/dtb-$KVER/rockchip/rk3528-nanopi-zero2.dtb"
expect "verify FAILS when the DTB is missing" 1 "$R" post_install_kernel_debs__900_wifi7_verify
mk_tree "$R"; mk_dtb "$R" okay; mv "$R/sdcard/boot/config-$KVER" "$R/sdcard/boot/config-6.1.115-vendor-rk35xx"
expect "verify FAILS on a 6.1 kernel" 1 "$R" post_install_kernel_debs__900_wifi7_verify
mk_tree "$R"; echo 'fdtfile=rockchip/rk3528-nanopi-rev01.dtb' > "$R/mount/boot/armbianEnv.txt"
expect "boot check FAILS on the vendor DTB name" 1 "$R" pre_umount_final_image__950_wifi7_boot_check
mk_tree "$R"; echo 'setenv bootargs "console=ttyS2,1500000"' > "$R/mount/boot/boot.cmd"
expect "boot check FAILS on console=ttyS2" 1 "$R" pre_umount_final_image__950_wifi7_boot_check
# prepare_config refusals
for b in vendor current; do
  ( display_alert() { :; }; exit_with_error() { exit 1; }; BRANCH=$b; source "$EXT"; extension_prepare_config__wifi7_mainline ) >/dev/null 2>&1; rc=$?
  if [[ $rc -eq 1 ]]; then echo "ok   : prepare_config refuses BRANCH=$b"; else echo "FAIL : prepare_config accepted BRANCH=$b"; overall=1; fi
done
( display_alert() { :; }; exit_with_error() { exit 1; }; BRANCH=bleedingedge; source "$EXT"; extension_prepare_config__wifi7_mainline && [[ "$WIFI7_FIRMWARE_REF" == 20260810 ]] ) >/dev/null 2>&1 && echo "ok   : prepare_config accepts bleedingedge and pins 20260810" || { echo "FAIL : prepare_config on bleedingedge"; overall=1; }
# firmware hook against a fake cache, in both linux-firmware layouts (intel/iwlwifi/ since 2026; top level before)
fw_case() {   # $1 label, $2 relative dir for the intel files
  mk_tree "$R"; rm -rf "$R/cache"; mkdir -p "$R/cache/sources/linux-firmware/$2" "$R/cache/sources/linux-firmware/rtw89"
  : > "$R/cache/sources/linux-firmware/$2/iwlwifi-gl-c0-fm-c0-c106.ucode"; : > "$R/cache/sources/linux-firmware/$2/iwlwifi-gl-c0-fm-c0-101.ucode"; : > "$R/cache/sources/linux-firmware/$2/iwlwifi-gl-c0-fm-c0.pnvm"; : > "$R/cache/sources/linux-firmware/rtw89/rtw8922a_fw-4.bin"
  rm -rf "$R"/sdcard/lib/firmware/*
  ( display_alert() { :; }; exit_with_error() { echo "$1"; exit 1; }; fetch_from_repo() { :; }; SDCARD="$R/sdcard"; SRC="$R"; BRANCH=bleedingedge; WIFI7_FIRMWARE_REF=20260810; WIFI7_FIRMWARE_REPOSITORY=x; source "$EXT"; post_install_kernel_debs__500_wifi7_firmware ) >/dev/null 2>&1
  [[ -f "$R/sdcard/lib/firmware/iwlwifi-gl-c0-fm-c0-c106.ucode" && -f "$R/sdcard/lib/firmware/iwlwifi-gl-c0-fm-c0.pnvm" && -f "$R/sdcard/lib/firmware/rtw89/rtw8922a_fw-4.bin" && ! -f "$R/sdcard/lib/firmware/iwlwifi-gl-c0-fm-c0-101.ucode" ]] && echo "ok   : firmware hook ($1): core files + pnvm + rtw8922a copied to top level, API-numbered ucode skipped" || { echo "FAIL : firmware hook ($1)"; overall=1; }
}
fw_case "intel/iwlwifi layout" "intel/iwlwifi"
fw_case "top-level layout" "."
# core patch override hook: copies userpatches/kernel-overrides/<dir>/x.patch over ${SRC}/patch/kernel/<dir>/x.patch
mk_tree "$R"; mkdir -p "$R/up/kernel-overrides/archive/rockchip64-7.3" "$R/patch/kernel/archive/rockchip64-7.3"
echo "fixed" > "$R/up/kernel-overrides/archive/rockchip64-7.3/x.patch"; echo "broken" > "$R/patch/kernel/archive/rockchip64-7.3/x.patch"; echo "keep" > "$R/patch/kernel/archive/rockchip64-7.3/y.patch"
( display_alert() { :; }; exit_with_error() { exit 1; }; SRC="$R"; USERPATCHES_PATH="$R/up"; KERNELPATCHDIR="archive/rockchip64-7.3"; BRANCH=bleedingedge; BOARD=nanopi-zero2; source "$EXT"; extension_finish_config__wifi7_mainline_core_patch_overrides ) >/dev/null 2>&1
[[ "$(cat "$R/patch/kernel/archive/rockchip64-7.3/x.patch")" == fixed && "$(cat "$R/patch/kernel/archive/rockchip64-7.3/y.patch")" == keep ]] && echo "ok   : core patch override replaces only the same-named core file" || { echo "FAIL : core patch override"; overall=1; }
echo "overall=$overall"; exit $overall
