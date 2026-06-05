#!/usr/bin/env bash
# Stage 3 — EL2 boot stack: slbounce + tcblaunch + EL2 dtb + systemd-boot entry.
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
need_root; load_env
# shellcheck disable=SC1091
[ -f "$HERE/config/.build.env" ] && source "$HERE/config/.build.env"
: "${KERNEL_RELEASE:?run scripts/02-install-kernel.sh first}"
: "${KERNEL_SRC:?run scripts/02-install-kernel.sh first}"

DRV="$ESP/EFI/systemd/drivers"; install -d "$DRV"
SLOT="$ESP/$MACHINE_ID/$KERNEL_RELEASE"; install -d "$SLOT"

# --- systemd-boot ---
command -v bootctl >/dev/null && bootctl install --graceful >/dev/null 2>&1 || true

# --- slbounce EFI drivers (open source: github.com/TravMurav/slbounce) ---
# Build them (make) and drop qebspilaa64.efi + slbounceaa64.efi into SLBOUNCE_DIR,
# or reuse an already-working ESP. Filenames MUST end in 'aa64'.
SLBOUNCE_DIR="${SLBOUNCE_DIR:-$HERE/config/slbounce}"
for d in qebspilaa64.efi slbounceaa64.efi; do
	if [ -f "$SLBOUNCE_DIR/$d" ]; then install -m644 "$SLBOUNCE_DIR/$d" "$DRV/$d"; ok "driver: $d"
	elif [ -f "$DRV/$d" ]; then ok "driver: $d (already on ESP)"
	else warn "MISSING $d — build it from the slbounce project into $SLBOUNCE_DIR (see docs/el2-boot.md)"; fi
done

# --- tcblaunch.exe (Microsoft DRTM binary, NOT redistributable — extract it) ---
# slbounce only bounces a SPECIFIC build. See docs/tcblaunch.md.
TCB="$ESP/tcblaunch.exe"
if [ -f "$TCB" ]; then
	ok "tcblaunch.exe present on ESP"
else
	cand="$(fw_find tcblaunch.exe || true)"
	if [ -n "$cand" ]; then install -m644 "$cand" "$TCB"; ok "tcblaunch.exe extracted ($cand)"
	elif [ -n "${TCBLAUNCH_ISO:-}" ]; then "$HERE/scripts/extract-tcblaunch.sh" "$TCBLAUNCH_ISO"
	else warn "tcblaunch.exe NOT found — set TCBLAUNCH_ISO (a 24H2 $TCBLAUNCH_VERSION ISO) or read docs/tcblaunch.md"; fi
fi
# Best-effort version sanity check (warn only).
if [ -f "$TCB" ] && command -v strings >/dev/null; then
	if ! strings "$TCB" 2>/dev/null | grep -q "$TCBLAUNCH_VERSION"; then
		warn "tcblaunch.exe may NOT be the slbounce-compatible build $TCBLAUNCH_VERSION."
		warn "Newer Windows ships an incompatible tcblaunch — see docs/tcblaunch.md to get the right one."
	fi
fi

# --- EL2 device tree (built in stage 2) ---
DTB_SRC="$KERNEL_SRC/arch/arm64/boot/dts/qcom/x1p42100-asus-zenbook-a14-el2.dtb"
[ -f "$DTB_SRC" ] || die "EL2 dtb missing: $DTB_SRC (did 'make dtbs' run?)"
install -d "$ESP/dtbs"
install -m644 "$DTB_SRC" "$ESP/dtbs/x1p42100-asus-zenbook-a14-el2-jg.dtb"
ok "EL2 dtb installed"

# --- kernel image + initrd into the boot slot ---
install -m644 "$KERNEL_SRC/arch/arm64/boot/Image" "$SLOT/linux"
if command -v update-initramfs >/dev/null; then
	update-initramfs -c -k "$KERNEL_RELEASE" >/dev/null 2>&1 || true
	[ -f "/boot/initrd.img-$KERNEL_RELEASE" ] && install -m644 "/boot/initrd.img-$KERNEL_RELEASE" "$SLOT/initrd"
elif command -v dracut >/dev/null; then
	dracut -f "$SLOT/initrd" "$KERNEL_RELEASE"
fi
[ -f "$SLOT/initrd" ] || warn "no initrd generated — check your initramfs tool"
ok "kernel + initrd staged in $SLOT"

# --- systemd-boot entry ---
ENTRY="$ESP/loader/entries/el2jg-$KERNEL_RELEASE.conf"
install -d "$ESP/loader/entries"
cat > "$ENTRY" <<EOF
title    ASUS Zenbook A14 — EL2-JG ($KERNEL_RELEASE)
version  $KERNEL_RELEASE
sort-key ubuntu-el2jg
linux    /$MACHINE_ID/$KERNEL_RELEASE/linux
initrd   /$MACHINE_ID/$KERNEL_RELEASE/initrd
devicetree /dtbs/x1p42100-asus-zenbook-a14-el2-jg.dtb
options  root=UUID=$ROOT_UUID $KERNEL_CMDLINE systemd.machine_id=$MACHINE_ID
EOF
grep -q '^default'  "$ESP/loader/loader.conf" 2>/dev/null || echo 'default el2jg-*' >> "$ESP/loader/loader.conf"
grep -q '^timeout'  "$ESP/loader/loader.conf" 2>/dev/null || echo 'timeout 5'      >> "$ESP/loader/loader.conf"
ok "boot entry: $(basename "$ENTRY")"
ok "EL2 boot stage done"
