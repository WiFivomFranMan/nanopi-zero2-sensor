# Hardware bring-up (HUMAN throughout)

Prerequisites, all of them the user's to provide: the board is **free** (no antenna or other
campaign running on it — ask), a spare SD card, a 3.3 V USB-UART adapter that can do
**1,500,000 baud** (many CP2102 boards cannot; FT232R/CP2104/CH343 can), and a window of an hour.

The vendor SD card is never overwritten. It is the rollback.

## 0. The "before" column — on the VENDOR image, before anything is flashed

This has never been captured (the image ships no SSH key, so every automated attempt failed).
Log in with the password (`sshpass -p pi ssh pi@wlanpi-nano-5430.local`) or via serial, and
save the output verbatim to `Docs/bringup/before-<date>.txt` in the fork:

```bash
uname -a; cat /etc/armbian-release; tr -d '\0' </proc/device-tree/model; echo
cat /proc/cmdline; cat /boot/armbianEnv.txt; lsblk -o NAME,SIZE,MOUNTPOINT   # SD or eMMC?
ip -br link; ls /sys/class/net; ls /sys/class/udc                            # end1, wlp1s0f0, mon0, UDC name
lspci -nn; lsusb                                                              # 8086:272b; any 8087:xxxx BT?
ethtool -i end1; cat /sys/class/net/end1/phydev/phy_id 2>/dev/null; dmesg | grep -iE 'phy|mdio|end1' | head
modinfo iwlwifi | grep -E '^(version|filename)'; lsmod | grep -E 'iwl|80211'
dmesg | grep -iE 'iwlwifi.*(loaded firmware|Detected|op_mode)' | head -5
iw list | grep -iE 'Wiphy|EHT|320|\* monitor' | head
cat /sys/class/thermal/thermal_zone*/temp                                     # idle; repeat after 10 min of capture
dmesg | grep -ciE 'Microcode SW error'                                        # baseline BEFORE any test
ss -ltnp | grep -E ':22|:31415'
```

## 1. Flash the spare card

```bash
xz -dc intuitibits-nanopi-zero2-v1.1.0-wc1-bleedingedge.img.xz | sudo dd of=/dev/sdX bs=4M status=progress conv=fsync
```
Double-check `/dev/sdX`. Label the card physically.

## 2. Serial console first, network second

Header: the 8-pin 2.54 mm header; pins silkscreened `UART2DBG_TX`/`UART2DBG_RX` + GND, 3.3 V,
1500000 8N1. Vendor calls it `ttyS2`; mainline `ttyS0`; same pins.

```bash
screen /dev/tty.usbserial-XXXX 1500000      # or picocom -b 1500000
```

Power on with the card inserted. Predicted failure modes and what each looks like — all of them
are invisible without the console:

| Symptom on console | Cause | Fix |
|---|---|---|
| U-Boot: `No valid device tree binary found` / `Please RESET the board` | 0-byte FDT in cached U-Boot (#9508) | rebuild with `WC_IGNORE_CACHE=yes` |
| U-Boot loads `rk3528-nanopi-rev01.dtb` and fails, or kernel silent | vendor DTB name on mainline (bleedingedge boot glue missing) | `armbianEnv.txt` `fdtfile=` — the extension's `extension_finish_config__` assertion should have prevented this |
| Kernel: `synchronous external abort` / SError in `rockchip_pmu_set_idle_request` | pmdomain fix not applied | check the build log for `rk3528-pmdomain-…` |
| `MDIO device at address 1 is missing` / no `end0` | PHY reset ordering or PHY driver | `rk3528-14` applied? `CONFIG_MOTORCOMM_PHY`/`REALTEK_PHY` in config? |
| Boot loops every 10–30 s after userspace | dw-wdt left running by firmware, nothing pinging it | `cat /sys/class/watchdog/watchdog0/state`; `dmesg | grep -i wdt`; set `RuntimeWatchdogSec` in systemd or disable |
| No login prompt at 1500000 but garbage | adapter cannot do the baud | different adapter |

Record the full boot log to a file.

## 3. Ethernet

```bash
ip -br link                       # end0 (not end1) UP
ethtool end0 | grep -E 'Speed|Duplex|Link'     # 1000Mb/s Full
cat /sys/class/net/end0/phydev/phy_id; dmesg | grep -iE 'phy|mdio'   # settles RTL8211F vs YT8531S
ip addr show end0                 # DHCP lease AND 172.16.0.1/24
iperf3 -c <lab host>              # install iperf3 first; gigabit on mainline has no published measurement
```
Cold-boot ten times (power cycle, not reboot) and count how many times `end0` appears — the PHY
reset ordering question is only answerable this way.

## 4. USB-C gadget (NCM)

With the USB-C cable to a laptop **at boot**: `ls /sys/class/udc` (expect `fe500000.usb`),
`ip -br link show usb0`, laptop gets `192.168.7.x`. Then unplug, replug: `journalctl -u
usb-gadget-rebind` shows a run per plug; `usb0` comes back. Then boot **without** the cable and
plug in later: same expectation (this is the case the udev rule exists for).

## 5. PCIe and the BE200

```bash
lspci -nn                                   # 8086:272b at 0000:01:00.0 (bus number may differ from vendor)
lspci -vv -s 01:00.0 | grep -E 'LnkSta|MSI'  # 5GT/s x1; MSI enabled
dmesg | grep -iE 'iwlwifi|iwlmld' | head -20
```
Must show `op_mode iwlmld` (or `loaded firmware version 106.… op_mode iwlmld`) and `loaded
firmware … c106` (7.2/7.3). Must **not** show `No config found for PCI dev 272b` (that is
`CONFIG_IWLMLD` missing) or firmware `-2`/`-22` errors. `lsmod | grep iwlmld`.
`ls /sys/class/net` → `wlp1s0` or `wlp1s0f0` (name may lose the `f0` on mainline; WLAN Commander
discovers by `iw dev`, nothing in the image hardcodes it).

## 6. Wi-Fi 7 capture — the reason the sensor exists

```bash
iw list | grep -E 'EHT|320 MHz|\* monitor'
```
Then WLAN Commander's own sequence by hand (from the `intel-wifi-monitor` memory / the app's
`interface_setup.rs`): create `mon0`, bring it UP, run a managed-mode scan on the same PHY with
the monitor **up**, then `iw dev wlp1s0 scan freq 5975 6115 6535 6895`, bring the managed
interface DOWN, set `otherbss`, then:

```bash
sudo iw dev mon0 set freq 5955 320 6105 2>&1; iw dev mon0 info      # 6 GHz ch 1, 320 MHz
sudo timeout 20 tcpdump -i mon0 -c 200 -w /tmp/ch1-320.pcap; ls -la /tmp/ch1-320.pcap
```
Repeat at 5955/20, 6135/80, 6295/160, 6615/160 and a 5 GHz 80 MHz channel; count beacons per
capture and compare against the vendor "before" numbers. Zero frames after the regulatory dance
is the known Intel failure mode (monitor vif not up during the scan) — and, on a chanctx driver
like iwlmld after mac80211's 7.x monitor rework, possibly a new one; record it either way.
Then let the app do it: on the same LAN, WLAN Commander must list `wlanpi-nano-<serial>`, connect
with `pi`/`pi`, and complete Scan → Clients → Capture on 6 GHz at 320 MHz.

Stability: sample `dmesg | grep -c 'Microcode SW error'` **before** starting, run a 4-hour hop
capture, sample again; then one driver reload (`modprobe -r iwlmld iwlwifi; modprobe iwlwifi`)
and one reboot. Do not loop reloads — that harness was the source of the 6.1 "instability".

## 7. Temperature

Mainline has no thermal zone (`/sys/class/thermal` is empty). Record case temperature with an
external probe or IR thermometer at idle and after the 10-minute capture above, next to the
vendor `thermal_zone0` numbers from step 0. If the SoC runs hot in the enclosure, cap the OPP
(drop the 2016 MHz point via a DT overlay) before field use.

## 8. Rollback

`checklists/rollback.md`. Swap the SD card back. Nothing on the vendor card was touched.
