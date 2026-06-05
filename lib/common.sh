#!/usr/bin/env bash
# Shared helpers for the zenbook-a14-linux installer.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

c_red=$'\033[31m'; c_grn=$'\033[32m'; c_ylw=$'\033[33m'; c_blu=$'\033[34m'; c_rst=$'\033[0m'
log()  { printf '%s[a14]%s %s\n' "$c_blu" "$c_rst" "$*"; }
ok()   { printf '%s[ ok ]%s %s\n' "$c_grn" "$c_rst" "$*"; }
warn() { printf '%s[warn]%s %s\n' "$c_ylw" "$c_rst" "$*" >&2; }
die()  { printf '%s[fail]%s %s\n' "$c_red" "$c_rst" "$*" >&2; exit 1; }

need_root() { [ "$(id -u)" -eq 0 ] || die "run as root (sudo)"; }

load_env() {
	local env="$HERE/config/install.env"
	[ -f "$env" ] || die "missing $env (copy/edit it first)"
	# shellcheck disable=SC1090
	source "$env"
	: "${ROOT_UUID:?set ROOT_UUID in config/install.env}"
	: "${ESP:=/boot/efi}"
	[ -n "${MACHINE_ID:-}" ] || MACHINE_ID="$(cat /etc/machine-id)"
	[ -d "$ESP" ] || die "ESP $ESP not mounted"
}

# Confirm we're actually on a Zenbook A14 / x1p42100 before touching anything.
assert_a14() {
	local model="" soc=""
	model="$(cat /sys/class/dmi/id/product_name 2>/dev/null || true)"
	soc="$(tr -d '\0' < /sys/firmware/devicetree/base/compatible 2>/dev/null || true)"
	case "$model$soc" in
		*UX3407Q*|*x1p42100*|*zenbook-a14*) ok "detected ASUS Zenbook A14 / x1p42100" ;;
		*) warn "could not positively identify an A14 (model='$model'). Continue only if you are sure." ;;
	esac
}

# Decompress-aware install: copies src -> dest, creating dirs, 0644.
install_fw() {
	local src="$1" dest="$2"
	[ -f "$src" ] || { warn "firmware source missing: $src"; return 1; }
	install -D -m644 "$src" "$dest"
	ok "fw: ${dest#/lib/firmware/}"
}

# All configured firmware search roots, in priority order: official driver
# folder(s), BSP dump(s), and a mounted Windows partition (DriverStore).
fw_roots() {
	if [ "${FW_SOURCES+x}" = x ] && [ "${#FW_SOURCES[@]}" -gt 0 ]; then printf '%s\n' "${FW_SOURCES[@]}"; fi
	[ -n "${DRIVER_DIR:-}" ]  && printf '%s\n' "$DRIVER_DIR"
	[ -n "${BSP_DIR:-}" ]     && printf '%s\n' "$BSP_DIR"
	if [ -n "${WINDOWS_MOUNT:-}" ]; then
		local ds="$WINDOWS_MOUNT/Windows/System32/DriverStore/FileRepository"
		[ -d "$ds" ] && printf '%s\n' "$ds" || printf '%s\n' "$WINDOWS_MOUNT"
	fi
}

# Find a firmware file by name across every configured root (first hit wins).
# Official driver downloads, BSP dumps and DriverStore all just get searched.
fw_find() {
	local name="$1" r f
	while IFS= read -r r; do
		[ -d "$r" ] || continue
		f="$(find "$r" -iname "$name" -type f 2>/dev/null | head -1)"
		[ -n "$f" ] && { printf '%s\n' "$f"; return 0; }
	done < <(fw_roots)
	return 1
}

# Die unless at least one real firmware source exists; logs the valid ones.
fw_require_sources() {
	local r any=0
	while IFS= read -r r; do
		if [ -d "$r" ]; then ok "fw source: $r"; any=1; else warn "fw source missing (skipped): $r"; fi
	done < <(fw_roots)
	[ "$any" = 1 ] || die "no firmware source found — set FW_SOURCES / DRIVER_DIR / BSP_DIR / WINDOWS_MOUNT in config/install.env"
}
