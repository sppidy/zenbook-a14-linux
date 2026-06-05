# Why iris (HW video codec) is disabled

The Snapdragon's video engine (iris/VPU) is **unreachable from Linux on the A14**, and trying to use it **hard-resets the SoC**. iris is blacklisted on purpose; software video decode is used instead.

## Root cause

The SoC's **TME** (Trust Management Engine — the root-of-trust that partitions hardware to owners at boot, then forbids further access once locked) locks the VPU to a **secure / Windows-owned** domain. No VPU PAS authentication domain is exposed to Linux. Confirmed both ways:

| Attempt | Result |
|---|---|
| EL2, no-TZ firmware load (releases the Xtensa via `WRAPPER_TZ` XTSS reset — works on X1E) | **hard SoC reset** (non-secure write to the TME-locked VPU register = secure violation; no pstore) |
| EL1, PAS path, the device's *own signed* `qcvss8380.mbn` | **`qcom_scm_pas_init_image` → -22** (TZ refuses to authenticate the VPU image at all) |

The `-22` with the device's own signed firmware at **both** exception levels proves the VPU PD simply isn't provisioned for Linux — same class of wall as the camera-ALS/SSC secure path on this device. Upstream also keeps iris disabled on `x1-el2` for the related DT-binding reasons (Stephan Gerhold, Linaro).

The strongtz iris driver + X1P42100 platform data + the no-TZ loader are still present in the kernel tree (they're correct and work on X1E); only the `qcom_iris` module is blacklisted. If a future firmware/secure-world change ever exposes the VPU PD, remove `/etc/modprobe.d/blacklist-qcom-iris.conf` to re-test.
