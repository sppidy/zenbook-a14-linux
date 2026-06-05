# Linux on the ASUS Zenbook A14 (UX3407QA)

Mainline-based Linux for the **ASUS Zenbook A14 UX3407QA** — Qualcomm **Snapdragon X1 Plus** (`x1p42100`, "Hamoa"/"Purwa"). Boots Linux as the **EL2 host** via [slbounce](https://github.com/TravMurav/slbounce) + [qebspil](https://github.com/stephan-gh/qebspil), so **KVM works**.

> ⚠️ This modifies your bootloader and firmware setup. Read the whole README first. Keep your Windows install intact — you need it (once) to extract the proprietary Qualcomm/Microsoft firmware that is **not legally redistributable**.

Kernel: `7.1.0-rc6-a14-x1p-jg-el2+`, based on [jglathe's](https://github.com/jglathe/linux_ms_dev_kit) `ubuntu-qcom-x1e` tree + our X1P42100 camss/EC/EL2 work. Source branch: [`sppidy/linux@a14/jg-qcom-7.1-rc-6`](https://github.com/sppidy/linux/tree/a14/jg-qcom-7.1-rc-6).

## ⚠️ Status — validated against one machine, not yet a turnkey installer

This mirrors a **working** A14 and every stage was checked against that live machine (firmware names, the ESP boot layout, the slbounce/qebspil chain). But the installer **has not been run end-to-end on a fresh machine**. Treat it as a careful, reproducible *recipe*, not a guaranteed one-shot. Before relying on it:

- **Test on a spare rootfs or a second machine first** — it modifies your bootloader and firmware.
- **Firmware:** watch the extractor's `[warn] MISSING` lines — they tell you any blob your driver package didn't contain.
- **slbounce + tcblaunch:** build the EFI drivers from the slbounce project and supply the exact `tcblaunch.exe` build (`26100.6584`) — the wrong build silently fails to bounce. See `docs/el2-boot.md` and `docs/tcblaunch.md`.
- Your existing boot entries are kept; the installer only *adds* the EL2 one.

## Hardware status

| Component | Status | Notes |
|---|---|---|
| EL2 / KVM | ✅ | via slbounce; `/dev/kvm` live |
| CPU / suspend (s2idle) | ✅ | |
| Display (eDP panel) | ✅ | |
| GPU (Adreno X1-45) | ✅ | zap shader + GMU firmware |
| Wi-Fi + Bluetooth (WCN6855) | ✅ | `ath11k` (firmware in linux-firmware) |
| Keyboard / touchpad | ✅ | |
| Embedded Controller (fan, profile, kbd backlight) | ✅ | `asus-zenbook-a14-ec` + `hid-asus-ec` |
| Cameras (OV02C10 RGB + HM1092 IR) | ✅ | qcom camss (X1P42100 support) |
| Ambient Light Sensor → auto-brightness | ✅ | ov02c10 camera "color" sensor over SSC (`hexagonrpcd`, stage 05). Exposed two ways: the `autobright` daemon, and `iio-sensor-proxy`+libssc (stage 06 → `monitor-sensor`, GNOME native auto-brightness). See [docs/ssc-sensors.md](docs/ssc-sensors.md) |
| Audio | ✅ | WCD9395 / lpass |
| USB-C / DisplayPort-alt | ✅ | |
| **iris HW video codec** | ❌ **blocked** | VPU is TME-locked to the secure/Windows owner; no PAS PD for Linux. **Do not enable** — it hard-resets the SoC. SW video decode is used. See [docs/iris-wall.md](docs/iris-wall.md). |
| Physical motion sensors (accel/gyro/mag) | ❌ n/a | not fitted — the A14 chassis has no IMU. The only SSC sensor present is the camera-ALS above. |

## Requirements

- An A14 with its **Windows install still present** (or the ASUS recovery image) — needed once to extract proprietary firmware.
- A Linux rootfs already installed on the A14 (Ubuntu/Debian arm64). This package sets up the kernel + EL2 boot; it does not install a distro.
- Build host (the A14 itself is fine — native arm64): `git`, `gcc`/`clang`, `make`, `bc`, `flex`, `bison`, `libssl-dev`, `dtc`, `efibootmgr`, `systemd-boot`.
- ~15 GB free for the kernel build.

## Install (quick)

```bash
sudo ./install.sh
```

That runs, in order:

0. **`scripts/00-build-slbounce.sh`** — pulls + builds the `slbounce` + `qebspil` EFI drivers into `config/slbounce/`. See [docs/el2-boot.md](docs/el2-boot.md).
1. **`scripts/01-extract-firmware.sh`** — extracts the proprietary firmware from your Windows / official driver folder into `/lib/firmware/updates/…` (and the DSP blobs onto the ESP), and checks the redistributable Wi-Fi/BT/GPU firmware from linux-firmware. See [firmware/README.md](firmware/README.md).
2. **`scripts/02-install-kernel.sh`** — clones + builds the kernel branch with `config/kernel.config`, runs `modules_install`.
3. **`scripts/03-setup-el2-boot.sh`** — installs the built drivers + `tcblaunch.exe`, the EL2 device tree, and the systemd-boot entry.
4. **`scripts/04-apply-config.sh`** — iris blacklist, kernel cmdline, optional `autobright` ALS daemon.
5. **`scripts/05-setup-ssc-sensors.sh`** — brings up the SSC camera-ALS: installs `hexagonrpcd` + the patched daemon + systemd drop-ins, and lays down the sensor data tree (registry/config/firmware + the secure-DB seed). See [docs/ssc-sensors.md](docs/ssc-sensors.md).
6. **`scripts/06-setup-iio-sensor-proxy.sh`** — builds libssc + an SSC-enabled `iio-sensor-proxy` and exposes the camera-ALS on the standard `net.hadess.SensorProxy` D-Bus interface (GNOME native auto-brightness, `monitor-sensor`). See [docs/ssc-sensors.md](docs/ssc-sensors.md).

You can run each step on its own; they're idempotent. Edit `config/install.env` first (root UUID, Windows mount, kernel branch, etc.).

> **SSC data:** the sensor registry/config (generic 8380 reference set) is shipped in `ssc-data/`, so stage 05 works out of the box. Only the proprietary bits are extracted at install: the `dsp/` RFSA firmware (via `droid-juicer`) and the Microsoft-derived secure-DB seed (from your Windows). See [docs/ssc-sensors.md](docs/ssc-sensors.md).

## Firmware & licensing — read this

The proprietary Qualcomm DSP/GPU/video firmware (`qcadsp8380.mbn`, `qccdsp8380.mbn`, `qcdxkmsucpurwa.mbn`, `qcvss8380.mbn`, the `*_dtbs.elf`) and Microsoft's `tcblaunch.exe` are **licensed to the device** and **may not be redistributed**. They are **not** in this repo. `01-extract-firmware.sh` pulls them from *your own* Windows install (the same files Windows already ships), the way the [aarch64-laptops](https://github.com/aarch64-laptops/build) project does. The Wi-Fi/BT (`ath11k` WCN6855, `qca/htbtfw20.tlv`) and GPU (`gen71500_*`) firmware **is** freely redistributable (it's in [linux-firmware](https://gitlab.com/kernel-firmware/linux-firmware)) and is installed from there.

## Recovery

The installer keeps your existing boot entries and adds the EL2 one as the default (`default el2jg-*`). If a kernel update misbehaves, pick a previous entry in the systemd-boot menu, or the GRUB/EL1 entry. Windows Boot Manager stays in the UEFI boot menu.

## Credits

jglathe (X1E tree), strongtz/Wangao Wang (iris X1P42100), Stephan Gerhold & Linaro (iris no-TZ, qcom upstream, [qebspil](https://github.com/stephan-gh/qebspil)), TravMurav ([slbounce](https://github.com/TravMurav/slbounce)), aarch64-laptops, and the linux-arm-msm community.
