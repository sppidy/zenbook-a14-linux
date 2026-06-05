#!/usr/bin/env bash
# Stage 6 — iio-sensor-proxy with Qualcomm SSC support (libssc).
#
# Replaces the distro iio-sensor-proxy with an upstream build compiled
# -Dssc-support=enabled, plus libssc, so SSC sensors are exposed on the standard
# net.hadess.SensorProxy D-Bus interface (GNOME/KDE auto-brightness, monitor-sensor).
#
# NOTE for the A14 specifically: libssc's light driver looks up the standard
# 'ambient_light' SSC sensor, but the A14 has none — its ALS is the camera-QSH
# 'color' sensor (what the stage-04 autobright daemon reads directly). So out of
# the box iio-sensor-proxy finds no light sensor here; see docs/ssc-sensors.md
# ("iio-sensor-proxy & the A14"). This stage still sets up the full stack (and
# works for any real SSC accel/gyro/mag/als a future board exposes).
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
need_root; load_env

LIBSSC_REPO="${LIBSSC_REPO:-https://codeberg.org/DylanVanAssche/libssc.git}"
LIBSSC_BASE="${LIBSSC_BASE:-5538435e96646adcdc4a651fe4982a8e13c3ff5a}"   # commit the light patch is cut against
ISP_REPO="${ISP_REPO:-https://gitlab.freedesktop.org/hadess/iio-sensor-proxy.git}"
LIBSSC_BUILD="${LIBSSC_BUILD:-$HOME/zenbook-a14-libssc-build}"
ISP_BUILD="${ISP_BUILD:-$HOME/zenbook-a14-iio-sensor-proxy-build}"
LIBSSC_PATCH="$HERE/config/iio-sensor-proxy/0001-libssc-light-data-type-env.patch"
ISP_DROPINS="$HERE/config/iio-sensor-proxy/dropins"

# --- 1. build deps -----------------------------------------------------------
if command -v apt-get >/dev/null; then
	DEBIAN_FRONTEND=noninteractive apt-get install -y \
		build-essential meson ninja-build git pkg-config \
		python3 python-is-python3 python3-dev qrtr-tools libprotobuf-c-dev libprotobuf-dev \
		protobuf-c-compiler protobuf-compiler python3-gi libmbim-glib-dev libqmi-glib-dev \
		python3-protobuf libqrtr1 \
		libglib2.0-dev libgudev-1.0-dev libpolkit-gobject-1-dev systemd-dev \
		|| warn "apt install of build deps failed — install them manually"
else
	warn "non-apt distro: install meson/ninja/gcc, glib/gudev/polkit-gobject/systemd dev + qrtr/protobuf-c yourself"
fi

# --- 2. libssc (Qualcomm Sensor Core client lib) -----------------------------
# Provides libssc-sensor*.h + ssccli; iio-sensor-proxy's SSC drivers link it.
# We pin it to LIBSSC_BASE and apply a small patch so the light sensor's data
# type is overridable via SSC_LIGHT_DATA_TYPE — the A14's ALS is the camera-QSH
# 'color' sensor, not the standard 'ambient_light' libssc looks up by default.
if [ -d "$LIBSSC_BUILD/.git" ]; then git -C "$LIBSSC_BUILD" fetch origin 2>/dev/null || true
else git clone "$LIBSSC_REPO" "$LIBSSC_BUILD"; fi
git -C "$LIBSSC_BUILD" checkout -q "$LIBSSC_BASE" 2>/dev/null || die "cannot checkout libssc base $LIBSSC_BASE"
git -C "$LIBSSC_BUILD" checkout -- . 2>/dev/null || true
if [ -f "$LIBSSC_PATCH" ]; then
	git -C "$LIBSSC_BUILD" apply "$LIBSSC_PATCH" 2>/dev/null || git -C "$LIBSSC_BUILD" apply --3way "$LIBSSC_PATCH" \
		|| die "libssc light patch did not apply onto $LIBSSC_BASE"
	ok "applied libssc light-data-type patch (SSC_LIGHT_DATA_TYPE)"
else
	warn "missing $LIBSSC_PATCH — the A14 ALS ('color') will NOT be exposed (only standard 'ambient_light')"
fi
( cd "$LIBSSC_BUILD" && rm -rf _build \
	&& meson setup _build --prefix=/usr --libdir="lib/$(gcc -dumpmachine)" \
	&& meson compile -C _build )
meson install --no-rebuild -C "$LIBSSC_BUILD/_build" || die "libssc install failed"
ldconfig
pkg-config --exists libssc && ok "libssc $(pkg-config --modversion libssc) installed" || die "pkg-config still can't find libssc"

# --- 3. remove the distro iio-sensor-proxy, build the SSC-enabled one ---------
# gnome-shell/gnome-settings-daemon only *recommend* it, so removing it is safe.
if dpkg -s iio-sensor-proxy >/dev/null 2>&1; then
	command -v apt-get >/dev/null && DEBIAN_FRONTEND=noninteractive apt-get remove -y iio-sensor-proxy || true
	ok "removed distro iio-sensor-proxy"
fi
if [ -d "$ISP_BUILD/.git" ]; then git -C "$ISP_BUILD" pull --ff-only 2>/dev/null || true
else git clone --depth 1 "$ISP_REPO" "$ISP_BUILD"; fi
( cd "$ISP_BUILD" && rm -rf _build \
	&& meson setup _build --prefix=/usr -Dssc-support=enabled \
	&& meson compile -C _build )
meson install --no-rebuild -C "$ISP_BUILD/_build" || die "iio-sensor-proxy install failed"
ldconfig

# verify the SSC backend actually linked
if ldd /usr/libexec/iio-sensor-proxy 2>/dev/null | grep -q libssc; then ok "iio-sensor-proxy links libssc (SSC backend in)"
else warn "iio-sensor-proxy did NOT link libssc — was -Dssc-support=enabled honoured?"; fi

# --- 4. service drop-ins (A14: point the light sensor at the 'color' SUID) ---
DI=/etc/systemd/system/iio-sensor-proxy.service.d; install -d "$DI"
if [ -d "$ISP_DROPINS" ]; then
	for f in "$ISP_DROPINS"/*.conf; do install -m644 "$f" "$DI/"; ok "drop-in: $(basename "$f")"; done
else
	warn "missing $ISP_DROPINS — set Environment=SSC_LIGHT_DATA_TYPE=color yourself or the A14 ALS won't show"
fi

# --- 5. udev: tag the fastrpc node + reload ----------------------------------
# The shipped 80-iio-sensor-proxy.rules tags /dev/fastrpc-adsp* as
# 'ssc-light ssc-compass'. Reload + trigger so the running device picks it up.
udevadm control --reload
udevadm trigger --subsystem-match=misc --action=add 2>/dev/null || true
systemctl daemon-reload

# --- 6. report what the SSC exposes here -------------------------------------
# iio-sensor-proxy is D-Bus-activated (static unit); it starts on demand. Probe
# whether any SSC sensor is actually discoverable on this machine. The A14 light
# sensor lives under the 'color' data type, so probe it with that override.
if command -v ssccli >/dev/null || [ -x "$LIBSSC_BUILD/_build/src/ssccli" ]; then
	cli="$(command -v ssccli || echo "$LIBSSC_BUILD/_build/src/ssccli")"
	SSC_LIGHT_DATA_TYPE="${SSC_LIGHT_DATA_TYPE:-color}" timeout 8 "$cli" --sensor light --timeout 5 >/dev/null 2>&1 \
		&& ok "SSC light sensor available (camera-QSH 'color' ALS)" || warn "SSC light sensor not readable yet — check hexagonrpcd (stage 05) is up"
	for s in accelerometer magnetometer proximity; do
		timeout 8 "$cli" --sensor "$s" --timeout 5 >/dev/null 2>&1 && ok "SSC sensor available: $s" || log "SSC sensor not present: $s (expected on the A14 — no IMU)"
	done
fi

ok "iio-sensor-proxy + libssc stage done."
log "check exposed sensors with:  monitor-sensor    (expect 'Light changed: … (lux)')"
log "GNOME: Settings -> Power -> 'Automatic Screen Brightness' now uses this; you can then disable the autobright daemon (stage 04) if you prefer."
