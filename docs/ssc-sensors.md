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

## iio-sensor-proxy & the A14 (stage 06)

Stage 06 replaces the distro `iio-sensor-proxy` with an upstream build compiled
`-Dssc-support=enabled`, plus **libssc** (Qualcomm Sensor Core client lib), so
the SSC sensors appear on the standard `net.hadess.SensorProxy` D-Bus interface
— i.e. GNOME/KDE native auto-brightness and `monitor-sensor` work.

The A14 twist: libssc's light driver looks up the standard **`ambient_light`**
SSC sensor, but the A14 has none — its ALS is the camera-QSH **`color`** sensor
(the same one `autobright` reads). The complete A14 SSC inventory is just:

| data_type | sensor |
|---|---|
| `color` | camera-QSH ALS (lux + CCT) |
| `camera_face_detect` | camera presence / face detect |
| `camera_handshake` | camera handshake gesture |
| `registry` | the SUID-lookup service |

No `accel`/`gyro`/`mag`/`proximity`/`ambient_light` — the A14 has no IMU, and the
accel/gyro JSONs in the registry are Qualcomm's generic 8380 reference superset
(it configures four different IMU vendors; `sns_reg_config` `owner` is `"NA"` and
the entries are `8380_crd_*`, i.e. Compute Reference Design — not the A14 BOM).
A configured-but-absent chip never registers, which is why the SUID lookup is
empty for them.

So stage 06 ships a one-line **libssc patch** (`config/iio-sensor-proxy/0001-…patch`)
making the light data type overridable via `SSC_LIGHT_DATA_TYPE`, and a systemd
drop-in (`config/iio-sensor-proxy/dropins/10-a14-color-als.conf`) that sets
`SSC_LIGHT_DATA_TYPE=color`. The `color` event carries `[lux, CCT]`; libssc takes
`intensity[0]` (= lux), exactly like a standard ALS.

After this, `monitor-sensor` reports real lux from the camera-ALS, and you can
let GNOME drive brightness (Settings → Power → *Automatic Screen Brightness*) and
disable the `autobright` daemon if you prefer.

## Verify

```bash
systemctl status hexagonrpcd            # active (running)  — SSC up
journalctl --user -u autobright -f      # lux=… cct=…K -> …/2047   (camera-ALS via the daemon)
monitor-sensor                          # 'Light changed: … (lux)' (camera-ALS via iio-sensor-proxy)
```

If `hexagonrpcd` crash-loops at `:279`, your seed is missing or not the foreign
Windows DB. If `monitor-sensor` shows *No ambient light sensor*, check that the
drop-in set `SSC_LIGHT_DATA_TYPE=color` and that `/dev/fastrpc-adsp*` is tagged
`ssc-light` (`udevadm info -q property -n /dev/fastrpc-adsp-secure`).
