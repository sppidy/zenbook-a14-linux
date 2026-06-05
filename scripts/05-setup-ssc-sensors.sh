#!/usr/bin/env bash
# Stage 5 — Snapdragon Sensor Core (SSC) bring-up: hexagonrpcd + the camera-ALS.
#
# This is what makes the OV02C10 "color" ambient-light sensor reachable over the
# SSC (QMI/QRTR). The stage-4 `autobright` daemon reads that sensor to drive
# screen brightness — without this stage the SSC sensor PD never comes up.
#
# Chain:  hexagonrpcd (FastRPC bridge, serves the DSP its firmware + registry)
#         -> ADSP sensor PD (SSC) -> QMI service 400 -> autobright.
#
# The hard part on the A14 is the sensor PD's registry-HMAC assert
# (sns_registry_sensor.c:279). A patched daemon + a *foreign* (Windows) secure-DB
# seed make the ADSP regenerate a fresh DB each boot instead of crashing.
# See docs/ssc-sensors.md.
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
need_root; load_env

HRPC_REPO="${HRPC_REPO:-https://github.com/linux-msm/hexagonrpc}"
HRPC_BASE="${HRPC_BASE:-dd9ac70c026e1bad93e8cffa3801255b8ceb551e}"  # commit the patch is cut against
HRPC_BUILD="${HRPC_BUILD:-$HOME/zenbook-a14-hexagonrpc-build}"
PATCH="$HERE/config/hexagonrpcd/0001-a14-ssc-writable-registry-bigbuf.patch"
DROPINS="$HERE/config/hexagonrpcd/dropins"
DJ_ROOT="/var/lib/droid-juicer/sensors"
REG="$DJ_ROOT/sensors/registry"
SEED="$DJ_ROOT/sns-secure-db-seed.bin"
LIBEXEC="/usr/libexec/hexagonrpc/hexagonrpcd"
# Full SSC data tree to lay down (sensors/{config,registry,sns_reg.*}, socinfo,
# dsp, seed). Primary: a capture from a working A14 (scripts/capture-ssc-data.sh).
SSC_DATA_SRC="${SSC_DATA_SRC:-$HERE/ssc-data}"

# --- 1. distro packages: daemon scaffolding + firmware/registry extractor -----
# hexagonrpcd : fastrpc user, base systemd unit, /usr/bin wrapper, suspend/resume.
# droid-juicer: extracts the DSP RFSA firmware + sensor registry into $DJ_ROOT.
# (both live in Ubuntu resolute/universe; on other distros install them yourself)
if command -v apt-get >/dev/null; then
	DEBIAN_FRONTEND=noninteractive apt-get install -y \
		hexagonrpcd droid-juicer meson ninja-build pkg-config build-essential libjson-c-dev \
		|| warn "apt install failed — install hexagonrpcd, droid-juicer + meson/ninja/gcc/json-c manually"
else
	warn "non-apt distro: install 'hexagonrpcd' + 'droid-juicer' + meson/ninja/gcc/json-c yourself"
fi
getent passwd fastrpc >/dev/null || warn "no 'fastrpc' user — the hexagonrpcd package normally creates it"

# --- 2. build + install the PATCHED daemon ------------------------------------
# Upstream linux-msm/hexagonrpc + our patch: a writable/self-regenerating
# registry, >256B listener input buffers, and apps_std write support — all
# required for the A14 sensor PD to attach instead of asserting at :279.
if [ -f "$PATCH" ] && command -v meson >/dev/null; then
	if [ -d "$HRPC_BUILD/.git" ]; then git -C "$HRPC_BUILD" fetch --depth 80 origin 2>/dev/null || true
	else git clone "$HRPC_REPO" "$HRPC_BUILD"; fi
	git -C "$HRPC_BUILD" checkout -q "$HRPC_BASE" 2>/dev/null || die "cannot checkout patch base $HRPC_BASE in $HRPC_BUILD"
	git -C "$HRPC_BUILD" checkout -- . 2>/dev/null || true
	git -C "$HRPC_BUILD" apply "$PATCH" 2>/dev/null || git -C "$HRPC_BUILD" apply --3way "$PATCH" \
		|| die "patch did not apply onto $HRPC_BASE — rebase $(basename "$PATCH")"
	rm -rf "$HRPC_BUILD/build"
	( cd "$HRPC_BUILD" && meson setup build >/dev/null && ninja -C build ) || die "hexagonrpcd build failed"
	built="$HRPC_BUILD/build/hexagonrpcd/hexagonrpcd"
	[ -x "$built" ] || die "build produced no hexagonrpcd binary at $built"
	install -d /usr/libexec/hexagonrpc
	[ -f "$LIBEXEC" ] && [ ! -f "$LIBEXEC.orig" ] && cp -a "$LIBEXEC" "$LIBEXEC.orig"
	install -m755 "$built" "$LIBEXEC"; ok "patched hexagonrpcd -> $LIBEXEC"
else
	warn "skipping daemon build (missing patch or meson) — the stock hexagonrpcd may not attach the SSC"
fi

# --- 3. systemd drop-ins ------------------------------------------------------
# seed-secdb (foreign DB each boot), writable-registry (ProtectSystem carve-out),
# wait-node (boot race on /dev/fastrpc-adsp), auto-secure (exec), safety (no loop).
DI=/etc/systemd/system/hexagonrpcd.service.d; install -d "$DI"
if [ -d "$DROPINS" ]; then
	for f in "$DROPINS"/*.conf; do install -m644 "$f" "$DI/"; ok "drop-in: $(basename "$f")"; done
else
	warn "missing $DROPINS — the SSC will not come up cleanly without the drop-ins"
fi

# --- 4. lay down the SSC data tree (device/vendor data — never committed) -----
# The ADSP sensor PD needs the full tree: the sensor config JSONs, the generated
# registry, sns_reg.conf/sns_reg_version, socinfo, the RFSA dsp libs, and the
# secure-DB seed. On the A14 droid-juicer (an Android extractor) cannot generate
# this — it comes from the device's Windows persist. Two sources, in order:
#   (a) a capture from a working A14  (scripts/capture-ssc-data.sh -> ssc-data/)
#   (b) the Windows persist tree       (SSC_PERSIST_SRC or under WINDOWS_MOUNT)
laid=0
if [ -d "$SSC_DATA_SRC" ] && [ -n "$(ls -A "$SSC_DATA_SRC" 2>/dev/null)" ]; then
	log "laying down SSC data from $SSC_DATA_SRC"
	install -d "$DJ_ROOT"
	cp -a "$SSC_DATA_SRC"/. "$DJ_ROOT"/
	laid=1; ok "SSC tree installed (config + registry + sns_reg.* + socinfo + dsp + seed)"
else
	# Windows persist fallback: .../DriverData/Qualcomm/fastRPC/persist/sensors
	persist="${SSC_PERSIST_SRC:-}"
	if [ -z "$persist" ] && [ -n "${WINDOWS_MOUNT:-}" ]; then
		persist="$(find "$WINDOWS_MOUNT" -ipath '*Qualcomm/fastRPC/persist/sensors' -type d 2>/dev/null | head -1)"
	fi
	if [ -n "$persist" ] && [ -d "$persist" ]; then
		log "extracting SSC config + registry from Windows persist: $persist"
		install -d -o fastrpc -g fastrpc "$DJ_ROOT/sensors" 2>/dev/null || install -d "$DJ_ROOT/sensors"
		# config JSONs + sns_reg.conf/sns_reg_version
		[ -d "$persist/config" ] && cp -a "$persist/config" "$DJ_ROOT/sensors/"
		for f in sns_reg.conf sns_reg_version; do [ -f "$persist/$f" ] && cp -a "$persist/$f" "$DJ_ROOT/sensors/"; done
		# the generated registry lives one level deeper on Windows (registry/registry)
		src_reg="$persist/registry/registry"; [ -d "$src_reg" ] || src_reg="$persist/registry"
		[ -d "$src_reg" ] && { install -d "$REG"; cp -a "$src_reg"/. "$REG"/; }
		laid=1; ok "SSC config + registry extracted from Windows (dsp libs still need droid-juicer/firmware)"
		if command -v droid-juicer >/dev/null && { [ ! -d "$DJ_ROOT/dsp" ] || [ -z "$(ls -A "$DJ_ROOT/dsp" 2>/dev/null)" ]; }; then
			log "running droid-juicer for the RFSA dsp libs"; droid-juicer 2>/dev/null || warn "droid-juicer did not populate $DJ_ROOT/dsp — reboot to run its initramfs hook"
		fi
	fi
fi
if [ "$laid" = 1 ] && [ -d "$REG" ] && [ -n "$(ls -A "$REG" 2>/dev/null)" ]; then
	ok "sensor registry present ($(ls "$REG" | wc -l) files)"
else
	warn "no SSC data laid down. Run 'sudo ./scripts/capture-ssc-data.sh' on a working A14
       to make ssc-data/, or set SSC_PERSIST_SRC to your Windows
       ...\\DriverData\\Qualcomm\\fastRPC\\persist\\sensors  — see docs/ssc-sensors.md."
fi

# --- 5. the secure-DB SEED (the foreign Windows DB) ---------------------------
# THE key trick: a non-empty *Windows-format* sns_secure_database.bin makes the
# ADSP regenerate a fresh, valid DB each boot rather than asserting at :279.
# The capture already includes it; otherwise pull it from Windows.
if [ ! -f "$SEED" ]; then
	cand=""
	[ -n "${SSC_SECDB_SEED:-}" ] && [ -f "$SSC_SECDB_SEED" ] && cand="$SSC_SECDB_SEED"
	if [ -z "$cand" ] && [ -n "${WINDOWS_MOUNT:-}" ]; then
		cand="$(find "$WINDOWS_MOUNT" -ipath '*DriverData/Qualcomm/fastRPC/persist/sensors*sns_secure_database.bin' -type f 2>/dev/null | head -1)"
	fi
	[ -z "$cand" ] && cand="$(fw_find sns_secure_database.bin 2>/dev/null || true)"
	if [ -n "$cand" ]; then install -m644 "$cand" "$SEED"; ok "secure-DB seed <- $cand"
	else warn "no secure-DB seed at $SEED. Copy your Windows
       C:\\Windows\\System32\\drivers\\DriverData\\Qualcomm\\fastRPC\\persist\\sensors\\registry\\registry\\sns_secure_database.bin
       to $SEED  (or set SSC_SECDB_SEED).  Without it the SSC sensor PD crashes at boot."; fi
fi

# --- 6. permissions + enable --------------------------------------------------
getent passwd fastrpc >/dev/null && chown -R fastrpc:fastrpc "$DJ_ROOT" 2>/dev/null || true
systemctl daemon-reload
systemctl enable --now hexagonrpcd.service >/dev/null 2>&1 || warn "could not start hexagonrpcd — check: journalctl -u hexagonrpcd -b"
( sleep 2; systemctl is-active --quiet hexagonrpcd && ok "hexagonrpcd active" \
	|| warn "hexagonrpcd not active yet — inspect: journalctl -u hexagonrpcd -b" )

ok "SSC sensor stage done."
log "verify the camera-ALS is streaming:  journalctl --user -u autobright -f   (expect 'lux=… cct=…K -> …')"
