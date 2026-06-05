#!/usr/bin/env bash
# Preflight — sanity-check the machine model, environment and config BEFORE
# anything is installed. Read-only; safe to run on its own:
#
#   ./scripts/preflight.sh
#
# install.sh runs this first and ABORTS on any hard failure. The machine-model
# check is the important guard — set A14_FORCE=1 to override it (e.g. an A14
# variant), at your own risk.
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"

fails=0
bad() { printf '%s[FAIL]%s %s\n' "$c_red" "$c_rst" "$*" >&2; fails=$((fails+1)); }

log "preflight — machine, environment, config"

# --- machine model (the important guard) -------------------------------------
arch="$(uname -m)"
[ "$arch" = "aarch64" ] && ok "arch: aarch64" || bad "arch is '$arch', expected aarch64 (this is an arm64 laptop)"

model="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
soc="$(tr -d '\0' < /sys/firmware/devicetree/base/compatible 2>/dev/null || true)"
case "$model$soc" in
	*UX3407Q*|*x1p42100*|*zenbook-a14*)
		ok "machine: ASUS Zenbook A14 / x1p42100 (model='${model:-?}')" ;;
	*)
		if [ "${A14_FORCE:-0}" = 1 ]; then
			warn "machine does NOT look like an A14 (model='${model:-?}', soc='${soc:0:48}') — A14_FORCE=1 set, continuing"
		else
			bad "machine does NOT look like an A14 (model='${model:-?}', soc='${soc:0:48}'). Set A14_FORCE=1 to override."
		fi ;;
esac

# --- environment -------------------------------------------------------------
command -v systemctl >/dev/null && ok "systemd present" || bad "no systemd — the installer uses systemd-boot + services"
command -v apt-get   >/dev/null && ok "apt (Debian/Ubuntu)" || warn "no apt — scripts assume Debian/Ubuntu; install build deps + packages yourself"
miss=""; for t in git make gcc; do command -v "$t" >/dev/null || miss="$miss $t"; done
[ -z "$miss" ] && ok "base build tools (git/make/gcc)" || warn "missing build tools:$miss (apt: build-essential git)"
miss=""; for t in meson ninja bootctl rsync; do command -v "$t" >/dev/null || miss="$miss $t"; done
[ -z "$miss" ] && ok "meson/ninja/bootctl/rsync present" || warn "not yet installed:$miss (stages apt-install meson/ninja; bootctl=systemd-boot, rsync=capture)"

# --- config (only if install.env exists) -------------------------------------
if [ -f "$HERE/config/install.env" ]; then
	# shellcheck disable=SC1090
	source "$HERE/config/install.env"
	: "${ESP:=/boot/efi}"
	if [ -n "${ROOT_UUID:-}" ] && [ -e "/dev/disk/by-uuid/$ROOT_UUID" ]; then
		ok "ROOT_UUID resolves -> $(readlink -f "/dev/disk/by-uuid/$ROOT_UUID")"
	else
		bad "ROOT_UUID='${ROOT_UUID:-<unset>}' matches no filesystem (set it: findmnt -no UUID /)"
	fi
	if mountpoint -q "$ESP" 2>/dev/null; then
		free=$(df -Pm "$ESP" 2>/dev/null | awk 'NR==2{print $4}')
		[ "${free:-0}" -ge 150 ] && ok "ESP mounted at $ESP (${free}MB free)" || warn "ESP $ESP only ${free}MB free — kernel+initrd+drivers need ~150MB"
	else
		bad "ESP '$ESP' is not a mountpoint (set ESP in config/install.env)"
	fi
	nsrc=0; [ "${FW_SOURCES+x}" = x ] && nsrc="${#FW_SOURCES[@]}"
	if [ "$nsrc" -eq 0 ] && [ -z "${DRIVER_DIR:-}${BSP_DIR:-}${WINDOWS_MOUNT:-}" ]; then
		warn "no firmware source set (FW_SOURCES/DRIVER_DIR/BSP_DIR/WINDOWS_MOUNT) — stages 01/05/06 need one"
	else
		ok "firmware source configured"
	fi
	rootfree=$(df -Pm / 2>/dev/null | awk 'NR==2{print $4}')
	[ "${rootfree:-0}" -ge 25000 ] && ok "rootfs free: $((rootfree/1024))GB" || warn "rootfs only $((rootfree/1024))GB free — a kernel build wants ~25GB"
else
	warn "config/install.env not found — copy + edit it before running install.sh"
fi

# --- heads-up (not failures — just know this) --------------------------------
printf '\n%s[heads-up]%s\n' "$c_ylw" "$c_rst"
cat <<'EOF'
  * This modifies your bootloader (systemd-boot) and firmware layout. Keep your
    Windows install: the proprietary Qualcomm firmware, Microsoft tcblaunch.exe
    and the SSC secure-DB seed are extracted from YOUR device (not redistributable),
    so have the Windows partition mounted (WINDOWS_MOUNT).
  * iio-sensor-proxy (06) and power-profiles-daemon (07) are SOURCE builds
    installed over the distro packages — a future `apt upgrade` will overwrite
    them. Re-run that stage afterwards, or pin them:
        sudo apt-mark hold iio-sensor-proxy power-profiles-daemon
  * The DSP firmware (dsp/) and the secure-DB seed are NOT in the repo; only the
    sensor registry/config is shipped. The rest is pulled at install time.
EOF

if [ "$fails" -gt 0 ]; then
	die "$fails preflight check(s) FAILED — fix the above before installing (A14_FORCE=1 overrides only the model check)"
fi
ok "preflight passed"
