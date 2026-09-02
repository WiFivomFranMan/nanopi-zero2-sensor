# Rollback

The unit boots from a microSD card. The mainline image goes on a **spare** card; the vendor
card is never written. Rolling back is: power off, swap the card, power on. Nothing else.

If the vendor card is lost or needs rebuilding:

```bash
# on the NUC
cd ~/nanopi-fork/sensor
ls build/output/images/archive/           # every previous image is archived here since 2026-09-02
WC_BRANCH=vendor ./build.sh               # rebuilds the 6.1 image on its own Armbian pin (v26.5.1), ~30 min warm
```

The vendor build path is unchanged by the mainline work: same Armbian commit, same
`iwlwifi-backport` extension (now guarded so it cannot run on another branch), same full
kernel config file. The only shared files are the overlay (`Name=end*` matches `end1` on vendor;
the gadget script's serial lookup falls through to `/proc/cpuinfo`; the udev rebind rule is
harmless where the UDC exists at boot) and `customize-image.sh`.

Do not "roll back" by `apt` on the device or by copying kernels between cards; the boot
layout (`fdtfile`, console, DTB directory) differs between the two kernels.
