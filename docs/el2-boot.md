# EL2 boot stack (qebspil + slbounce)

The A14 firmware hands the OS off at **EL1** (the Windows hypervisor normally owns EL2). To run Linux as the **EL2 host** — needed for **KVM** — two EFI drivers, auto-loaded by systemd-boot, run before the kernel:

1. **`qebspilaa64.efi`** (Qualcomm EFI PIL) — reads the DSP firmware from the ESP `firmware/` tree and the `/reserved-memory` ranges from the device tree, then **authenticates and starts the ADSP/CDSP**. Linux later *attaches* to these already-running DSPs (it cannot PAS-load them itself at EL2).
2. **`slbounceaa64.efi`** — opens `tcblaunch.exe` (ESP root) and performs the Windows DRTM **Secure-Launch bounce** that lands the next stage at **EL2** instead of the Windows hypervisor.

Then systemd-boot boots the `el2jg-*` entry: kernel + the EL2 device tree (`devicetree=`) + cmdline. **EL3 stays Qualcomm's TrustZone** throughout — none of this touches it.

> Verified by reading the strings out of the shipped binaries on the reference machine: `qebspil` → *"Failed to authenticate and start firmware … Failed to find /reserved-memory in DTB"*; `slbounce` → *"Opening file 'tcblaunch.exe' failed … exiting UEFI. Your system will crash if SL fails."*

## ESP layout this produces

```
$ESP/
├── EFI/systemd/drivers/
│   ├── qebspilaa64.efi      # DSP PIL          (build from slbounce; name MUST end -aa64)
│   └── slbounceaa64.efi     # EL2 bounce       (build from slbounce; name MUST end -aa64)
├── tcblaunch.exe            # Microsoft DRTM payload, build 26100.6584 — EXTRACT (docs/tcblaunch.md)
├── firmware/qcom/x1p42100/ASUSTeK/zenbook-a14/
│   └── qcadsp8380.mbn, adsp_dtbs.elf, qccdsp8380.mbn, cdsp_dtbs.elf   # qebspil loads these
├── dtbs/x1p42100-asus-zenbook-a14-el2-jg.dtb     # base dtb + x1-el2 overlay
└── <machine-id>/<kver>/{linux,initrd}
```

`EFI/slbounce/{slbounce.efi,dtbloader.efi}` may also be present from older setups — **not used** by this flow (the active drivers live in `EFI/systemd/drivers/`, and the dtb is loaded by systemd-boot's `devicetree=`). Safe to ignore.

## Building qebspil + slbounce (automated — `scripts/00-build-slbounce.sh`)

Stage 0 pulls and builds **both**, native on the A14, into `config/slbounce/`. They are **two separate upstreams**:

- **slbounce** — [github.com/TravMurav/slbounce](https://github.com/TravMurav/slbounce) — the EL2 Secure-Launch bounce. Build: `git submodule update --init --recursive && make` (gnu-efi / arm64-sysreg-lib / libfdt come in as submodules). Output `slbounce.efi` → `config/slbounce/slbounceaa64.efi`.
- **qebspil** — [github.com/stephan-gh/qebspil](https://github.com/stephan-gh/qebspil) — pre-boots the ADSP/CDSP in EL1 before the bounce. Output `qebspil.efi` → `config/slbounce/qebspilaa64.efi`.

Needs `build-essential` + `git`. `scripts/03-setup-el2-boot.sh` then installs both as `EFI/systemd/drivers/*aa64.efi` — the `-aa64` suffix is **required** (systemd-boot only auto-loads `*aa64.efi`).

## Dependencies / order

- `qebspil` needs the **DSP firmware on the ESP** (stage 1 puts it there) **and** the `/reserved-memory` nodes in the dtb — so run stage 1 (firmware) before first EL2 boot.
- `slbounce` needs the **right `tcblaunch.exe` build** — see [docs/tcblaunch.md]; the wrong build silently fails to bounce.
- Recovery: any non-EL2 entry (or GRUB/EL1) boots Linux at EL1 (no KVM) if the bounce fails.
