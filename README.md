# NanoPi Zero2 Sensor Image

A custom Armbian image that turns a [FriendlyElec NanoPi Zero2](http://www.friendlyarm.com/) into a headless Wi-Fi scanning and packet capture sensor for use with Intuitibits' Wi-Fi tools.

Requires an Intel BE200 Wi-Fi 6E (M.2) module; the board's onboard Wi-Fi is not supported. Connects over USB or Ethernet.

## Getting the image

Pre-built images are published on the [Releases page](https://github.com/intuitibits/nanopi-zero2/releases). Download `intuitibits-nanopi-zero2-v<version>.img`, and verify it against the accompanying `.img.sha` checksum.

If no release fits your needs, build it yourself: see [Building from source](#building-from-source).

## Flashing

Use any standard image-flashing tool, e.g. [balenaEtcher](https://etcher.balena.io/), or `dd`:

```bash
# Example only: replace /dev/sdX with your actual SD card device.
# Double-check the target device first: writing to the wrong one
# will destroy its data irrecoverably.
sudo dd if=intuitibits-nanopi-zero2-v1.0.0.img of=/dev/sdX bs=4M status=progress conv=fsync
```

## First boot

- Connect the NanoPi Zero2 to your computer via USB (it's reachable at `192.168.7.1`) or plug it into your network over Ethernet.
- Default login: user `pi`, password `pi`. The `root` account is locked by default; re-enable it later with `sudo passwd root` if needed.

  **Change the `pi` password before putting the device on any network you don't fully trust.** This is a public repository, so the default password is not a secret.

## Building from source

Requires `git`, `rsync`, and a host capable of running [Armbian's build system](https://docs.armbian.com/Developer-Guide_Build-Preparation/) (a supported Ubuntu/Debian host or VM; Docker is only needed as Armbian's own fallback for unsupported hosts).

```bash
./build.sh
```

The resulting image, checksum, and build log land in `build/output/images/` as `intuitibits-nanopi-zero2-v<IMAGE_VERSION>.*`.

To cut a new version, bump `IMAGE_VERSION` in `build.sh` and the `ver=` TXT record in `userpatches/overlay/etc/avahi/services/nanopizero2.service`.

See [CLAUDE.md](CLAUDE.md) for implementation details on the build and customizations.

## Troubleshooting

- **No USB connectivity**: check `systemctl status usb-gadget.service` on the device, and confirm your computer received a DHCP lease in `192.168.7.10`–`192.168.7.29`.
- **Build logs**: the renamed summary log is `build/output/images/intuitibits-nanopi-zero2-v<IMAGE_VERSION>.img.txt`; Armbian's detailed per-step logs are under `build/output/logs/`.

## License

This project is licensed under the [MIT License](LICENSE).
