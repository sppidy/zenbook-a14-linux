# SSC sensors & the camera-ALS (hexagonrpcd)

The A14 has **no physical IMU** (no accel/gyro/mag chips). Its one usable sensor
is the **OV02C10 front camera acting as an ambient-light + colour sensor**,
exposed by the Snapdragon Sensor Core (SSC) running on the ADSP. Auto-brightness
(`autobright`, stage 04) reads it; this stage (05) brings the SSC up.

## The chain

```
hexagonrpcd  ── FastRPC ──>  ADSP sensor PD (SSC)  ── QMI svc 400 / QRTR ──>  autobright
   |                              |
   serves the DSP its            reads its registry/config, brings up the
   firmware + registry from       qsh_camera_ov02c10 "color" sensor (lux + CCT)
   /var/lib/droid-juicer/sensors
```

`hexagonrpcd` is the userspace daemon that answers the DSP's file/RPC requests.
The DSP reads its **sensor registry** (per-sensor config) through it. If the
registry can't be served, or the secure-DB check fails, the sensor PD asserts
and the whole SSC goes down.

## The hard part — the registry-HMAC assert (`sns_registry_sensor.c:279`)

On a fresh boot the sensor PD wants to HMAC-verify its `sns_secure_database.bin`.
The Linux ADSP **can't run that HMAC/crypto path** (it returns `0x6f`), so the
assert `SNS_RC_SUCCESS == rc` trips and the PD crashes — **unless** it finds a
*foreign* (Windows/Microsoft-format) DB, in which case it **regenerates** a fresh
valid DB instead of verifying. The working configuration therefore:

1. runs a **patched `hexagonrpcd`** (writable/self-regenerating registry, >256 B
   listener buffers, `apps_std` write support) — `config/hexagonrpcd/*.patch`;
2. **seeds the foreign Windows DB** before every start (drop-in
   `50-seed-secdb.conf` copies `sns-secure-db-seed.bin` over
   `registry/sns_secure_database.bin`), so the ADSP regenerates each boot.

The 5 systemd drop-ins (`config/hexagonrpcd/dropins/`):

| drop-in | what it does |
|---|---|
| `50-seed-secdb.conf` | copy the foreign secure-DB seed in before each start |
| `60-writable-registry.conf` | `ReadWritePaths` carve-out (base unit is `ProtectSystem=strict`) so the daemon can regenerate the registry |
| `99-wait-node.conf` | wait up to ~60 s for `/dev/fastrpc-adsp` (boot race) |
| `auto-secure.conf` | exec the daemon against `…-adsp-secure` (fallback `…-adsp`) |
| `safety.conf` | `StartLimitBurst=2` / `Restart=no` so a crash can't loop and wedge the ADSP |

## What's device data (and where it comes from)

The whole `/var/lib/droid-juicer/sensors/` tree is Qualcomm/Microsoft-derived and
is **never committed** here (it's `.gitignore`d):

| piece | what | origin |
|---|---|---|
| `sensors/config/*.json` | source sensor definitions | Windows persist |
| `sensors/registry/*` | generated registry keys | regenerated from config (Windows seed) |
| `sensors/sns_reg.conf`, `sns_reg_version` | SNS registry metadata | Windows persist |
| `socinfo/*` | SoC identity (soc_id, hw_platform…) | the SoC |
| `dsp/*.so.1`, `dsp/adsp/*` | RFSA algorithm libs served to the ADSP | DSP firmware / `droid-juicer` |
| `sns-secure-db-seed.bin` | the foreign Windows secure DB | `…\DriverData\Qualcomm\fastRPC\persist\sensors\registry\registry\sns_secure_database.bin` |

`droid-juicer` is an **Android** firmware extractor — it does **not** produce this
on the A14, so the data is sourced from your own device:

- **Best:** capture it from a working A14 —
  `sudo ./scripts/capture-ssc-data.sh` writes `ssc-data/` (16 MB, gitignored),
  which stage 05 lays down verbatim.
- **From Windows:** set `SSC_PERSIST_SRC` to your Windows
  `…\DriverData\Qualcomm\fastRPC\persist\sensors` (or just `SSC_SECDB_SEED` for
  the seed alone) and let `droid-juicer` supply the `dsp/` libs.

## Verify

```bash
systemctl status hexagonrpcd            # active (running)
journalctl --user -u autobright -f      # lux=… cct=…K -> …/2047   (camera-ALS live)
```

If `hexagonrpcd` crash-loops at `:279`, your seed is missing or not the foreign
Windows DB. If `autobright` shows no lux, the SSC didn't bring up the color
sensor — check `journalctl -u hexagonrpcd -b`.
