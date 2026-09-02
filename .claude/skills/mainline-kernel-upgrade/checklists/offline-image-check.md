# Offline image check (on the build server, no board)

**HUMAN:** needs the NUC. Everything here is read-only against the image file; nothing is
flashed. Run it on every mainline image before it goes near an SD card, even though the build's
own verify hooks already ran — this is the independent re-check, and it covers U-Boot.

```bash
cd ~/nanopi-fork/sensor/build/output/images
IMG=$(ls -t intuitibits-nanopi-zero2-v*-*.img.xz | head -n1); echo "$IMG"
cat "${IMG%.img.xz}.build-info"                 # fork commit, armbian commit, branch, cache flag
xz -dk "$IMG"                                   # keeps the .xz
RAW="${IMG%.xz}"
sudo losetup -fP --show "$RAW"                  # prints /dev/loopN
L=/dev/loopN                                    # <- from the line above
lsblk "$L"                                      # expect p1 = /boot (ext4, 512 MB), p2 = /
mkdir -p /tmp/img && sudo mount "${L}p2" /tmp/img && sudo mount "${L}p1" /tmp/img/boot
```

## Kernel and config

```bash
ls /tmp/img/boot/config-* /tmp/img/boot/vmlinuz-* /tmp/img/boot/dtb-*/rockchip/rk3528-nanopi-zero2.dtb
for s in CONFIG_IWLMLD=m CONFIG_PCI_MSI=y CONFIG_PCIE_ROCKCHIP_DW_HOST=y CONFIG_PHY_ROCKCHIP_NANENG_COMBO_PHY=y \
         CONFIG_PHY_ROCKCHIP_INNO_USB2=y CONFIG_USB_CONFIGFS_NCM=y CONFIG_MOTORCOMM_PHY=y CONFIG_REALTEK_PHY=y \
         CONFIG_MT7925U=m CONFIG_ATH12K=m CONFIG_RTW89_8922AU=m CONFIG_DW_WATCHDOG=y; do
  grep -qx "$s" /tmp/img/boot/config-* && echo "ok  $s" || echo "MISSING $s"
done
find /tmp/img/lib/modules -name 'iwlmld.ko*' -o -name 'mt7925u.ko*' -o -name 'ath12k.ko*' -o -name 'rtw89_8922au.ko*'
```

## Device tree: the M.2 slot

```bash
dtc -I dtb -O dts -q /tmp/img/boot/dtb-*/rockchip/rk3528-nanopi-zero2.dtb | awk '/pcie@fe000000/,/^\t\t};/' | grep -E 'status|reset-gpios|pinctrl-0'
```
Expect `status = "okay"`, `reset-gpios = <0x.. 0x02 0x00>` (gpio1 RK_PA2), `pinctrl-0` present.
Also: `grep -c 'usb@fe500000' …` = 1 and its `dr_mode = "otg"`; `aliases { ethernet0 = "/soc/ethernet@ffbe0000"`.

## Firmware

```bash
ls -la /tmp/img/lib/firmware/iwlwifi-gl-c0-fm-c0-c10*.ucode /tmp/img/lib/firmware/iwlwifi-gl-c0-fm-c0.pnvm
ls /tmp/img/lib/firmware/mediatek/mt7925/ /tmp/img/lib/firmware/ath12k/WCN7850/hw2.0/ /tmp/img/lib/firmware/rtw89/ | head -20
```
At least one of c102..c106 must exist (7.2 loads c106 down to c102; 7.3 also accepts c107).

## Boot path (what U-Boot actually reads)

```bash
grep -E '^(fdtfile|console|extraargs|rootdev)=' /tmp/img/boot/armbianEnv.txt
grep -o 'console=ttyS[0-9],1500000' /tmp/img/boot/boot.cmd
ls -la /tmp/img/boot/boot.scr
```
Expect `fdtfile=rockchip/rk3528-nanopi-zero2.dtb` and `console=ttyS0,1500000`. `ttyS2` or the
`rk3528-nanopi-rev01.dtb` name means the bleedingedge boot glue did not run: do not flash.

## U-Boot (armbian/build#9508)

```bash
UB=$(ls -d /tmp/img/usr/lib/linux-u-boot-* | head -n1); ls "$UB"
dumpimage -l "$UB/u-boot.itb" | grep -E 'Image [0-9]|Data Size|Type'
```
Every `fdt` image must have a non-zero `Data Size` (a good build showed 7992 bytes). A 0-byte FDT
is the cached-artifact bug: rebuild with `WC_IGNORE_CACHE=yes`.

Also confirm the bootloader that will be written: `cat /tmp/img/usr/lib/u-boot/platform_install.sh`
(vendor spl-blobs layout: `idbloader.img` at sector 64, `u-boot.itb` at 16384).

## Overlay and services

```bash
cat /tmp/img/etc/systemd/network/10-ethernet.network | grep Name      # Name=end*
ls -la /tmp/img/etc/udev/rules.d/90-usb-gadget-udc.rules /tmp/img/etc/systemd/system/usb-gadget-rebind.service
ls -la /tmp/img/etc/systemd/system/sysinit.target.wants/usb-gadget.service /tmp/img/etc/systemd/system/multi-user.target.wants/wc-hostname.service
grep ver= /tmp/img/etc/avahi/services/nanopizero2.service
grep -E '^pi:' /tmp/img/etc/passwd; ls -la /tmp/img/home/pi/.ssh/authorized_keys 2>/dev/null || echo "no key baked in (password login only)"
grep -q 'NOPASSWD: ALL' /tmp/img/etc/sudoers.d/pi-nopasswd-wifi && echo "sudo ok"
```

## Cleanup

```bash
sudo umount /tmp/img/boot /tmp/img && sudo losetup -d "$L" && rm "$RAW"
```

Record the results (image name, `.build-info`, every "MISSING"/0-byte finding) in the PR or in
memory before moving to hardware.
