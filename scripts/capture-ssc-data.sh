#!/usr/bin/env bash
# Capture this machine's known-good SSC data tree (/var/lib/droid-juicer/sensors)
# into ssc-data/ so the installer (scripts/05) can reproduce the exact sensor
# bring-up on a reinstall or another A14.
#
# This is DEVICE/VENDOR data — the Qualcomm sensor registry/config/firmware and
# the Microsoft-derived secure-DB seed. It is .gitignored and must NOT be
# committed or redistributed. Run it once on a working machine:
#
#   sudo ./scripts/capture-ssc-data.sh            # -> ./ssc-data
#   sudo ./scripts/capture-ssc-data.sh /some/dir  # -> /some/dir
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
need_root

DJ=/var/lib/droid-juicer/sensors
OUT="${1:-$HERE/ssc-data}"
[ -d "$DJ" ] || die "$DJ not present — nothing to capture (set up hexagonrpcd/droid-juicer first)"

install -d "$OUT"
# Copy the whole working tree EXCEPT the RE experiment snapshots (registry.pre*,
# registry-backup) — we only want the live, served set.
rsync -a --delete \
	--exclude 'sensors/registry.*' \
	--exclude 'sensors/registry-backup' \
	"$DJ"/ "$OUT"/

[ -f "$OUT/sns-secure-db-seed.bin" ] || warn "no sns-secure-db-seed.bin in the capture — the SSC will crash at boot without the foreign seed"
[ -d "$OUT/sensors/registry" ] && ok "registry: $(ls "$OUT/sensors/registry" | wc -l) files"
[ -d "$OUT/sensors/config" ]   && ok "config:   $(ls "$OUT/sensors/config"   | wc -l) files"
[ -f "$OUT/sensors/sns_reg.conf" ] && ok "sns_reg.conf + sns_reg_version present"
[ -d "$OUT/dsp" ]              && ok "dsp RFSA libs: $(find "$OUT/dsp" -type f | wc -l) files"
[ -d "$OUT/socinfo" ]          && ok "socinfo present"

# Hand ownership back to the invoking user so the repo stays editable.
own="${SUDO_USER:-root}"
chown -R "$own":"$(id -gn "$own" 2>/dev/null || echo "$own")" "$OUT" 2>/dev/null || true
ok "captured SSC data -> $OUT  ($(du -sh "$OUT" | cut -f1)).  It is .gitignored — keep it private."
