# Firmware

This directory is intentionally **empty of proprietary blobs**. Nothing copyrighted by Qualcomm, ASUS, or Microsoft is committed here.

## Proprietary (extracted from *your* Windows) — never redistributed

Listed in [`../config/firmware-manifest.txt`]. `../scripts/01-extract-firmware.sh` finds each by name under your `BSP_DIR` or `WINDOWS_MOUNT` and installs it to `/lib/firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/` (and the ESP where the boot chain needs it):

- `qcadsp8380.mbn`, `adsp_dtbs.elf` — Audio DSP
- `qccdsp8380.mbn`, `cdsp_dtbs.elf` — Compute DSP
- `qcdxkmsucpurwa.mbn` — GPU zap shader
- `qcvss8380.mbn` — video (iris; blacklisted but kept)
- `tcblaunch.exe` — Microsoft DRTM payload (see [`../docs/tcblaunch.md`])

### Where to get the blobs — any of these (the extractor searches them all)

Set one or more of `FW_SOURCES` / `DRIVER_DIR` / `BSP_DIR` / `WINDOWS_MOUNT` in `config/install.env`. Each file is found **by name** across every configured source, so they can complement each other.

1. **Official ASUS / Qualcomm driver download.** Grab the chipset/Qualcomm/wireless driver packages for the UX3407QA from ASUS support (or the Qualcomm driver bundle), extract the `.zip`s into a folder, and point `DRIVER_DIR` (or add it to `FW_SOURCES`) at it — the `.mbn`/`.elf` blobs sit inside the extracted `.inf` driver packages.
2. **A mounted Windows partition** (read-only):
   ```bash
   sudo mount -o ro /dev/nvme0n1p3 /mnt/windows   # your Windows (C:) partition
   # config/install.env:  WINDOWS_MOUNT="/mnt/windows"
   ```
   The firmware lives under `Windows/System32/DriverStore/FileRepository/qc*8380*/`.
3. **A BSP dump** via the [aarch64-laptops](https://github.com/aarch64-laptops/build) `qcom-firmware-extract` tool → point `BSP_DIR` at it.

## Redistributable (from linux-firmware) — installed, not bundled

These are free and ship in [linux-firmware](https://gitlab.com/kernel-firmware/linux-firmware); your distro's `linux-firmware` package provides them (use a recent version):

- Wi-Fi: `ath11k/WCN6855/hw2.1/{board-2.bin,amss.bin,m3.bin,regdb.bin}`
- Bluetooth: `qca/htbtfw20.tlv`, `qca/hpnv*`
- GPU: `qcom/gen71500_gmu.bin`, `qcom/gen71500_sqe.fw`
