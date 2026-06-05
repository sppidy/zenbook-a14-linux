#!/usr/bin/env bash
# Extract tcblaunch.exe from a Windows 11 24H2 (build 26100.6584) ISO or WIM/ESD,
# version-check it, and place it on the ESP for slbounce.
# Microsoft-proprietary — extracted from media you provide, never redistributed.
#
#   sudo ./scripts/extract-tcblaunch.sh /path/to/Win11_24H2_26100.6584.iso
#   (or set TCBLAUNCH_ISO in config/install.env and run with no argument)
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
need_root; load_env

ISO="${1:-${TCBLAUNCH_ISO:-}}"
WANT="${TCBLAUNCH_VERSION:-26100.6584}"
[ -n "$ISO" ] || die "usage: $0 <Win11-24H2-${WANT}.iso | install.wim/.esd>   (or set TCBLAUNCH_ISO)"
[ -f "$ISO" ] || die "not found: $ISO"
command -v wimextract >/dev/null || die "need wimlib-tools (apt install wimtools / wimlib-utils) for wimextract"

TMP="$(mktemp -d)"; trap 'umount "$TMP/mnt" 2>/dev/null || true; rm -rf "$TMP"' EXIT
WIM="$ISO"
if [[ "${ISO,,}" == *.iso ]]; then
	mkdir -p "$TMP/mnt"
	mount -o ro,loop "$ISO" "$TMP/mnt" || die "could not loop-mount $ISO"
	WIM="$(ls "$TMP/mnt"/sources/install.wim "$TMP/mnt"/sources/install.esd 2>/dev/null | head -1)"
	[ -n "$WIM" ] || die "no sources/install.wim(.esd) inside the ISO"
fi

log "extracting tcblaunch.exe from $(basename "$WIM")"
ok2=0
for img in 1 2 3 4 5 6; do
	if wimextract "$WIM" "$img" /Windows/System32/tcblaunch.exe --dest-dir="$TMP" >/dev/null 2>&1; then ok2=1; break; fi
done
OUT="$(find "$TMP" -iname tcblaunch.exe 2>/dev/null | head -1)"
[ "$ok2" = 1 ] && [ -n "$OUT" ] || die "could not extract tcblaunch.exe from any image in the WIM"

ver="$(strings -el "$OUT" 2>/dev/null | grep -oE '10\.0\.[0-9]{5}\.[0-9]+' | sort -u | head -1)"
log "extracted build: ${ver:-unknown}  (want $WANT)"
case "$ver" in
	*"$WANT"*) ok "matches the slbounce-compatible build $WANT" ;;
	*) warn "build '$ver' != $WANT — slbounce may not bounce. Use a 24H2 $WANT ISO (see docs/tcblaunch.md)" ;;
esac
install -m644 "$OUT" "$ESP/tcblaunch.exe"
ok "tcblaunch.exe -> $ESP/tcblaunch.exe"
