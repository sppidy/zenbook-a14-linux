#!/usr/bin/env bash
# Stage 1 — firmware.
#   * proprietary Qualcomm/ASUS blobs: extracted from YOUR Windows (per manifest)
#   * redistributable Wi-Fi/BT/GPU: from linux-firmware (installed by your distro)
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
need_root; load_env

MANIFEST="$HERE/config/firmware-manifest.txt"

# Search every configured source (official driver folder / BSP dump / Windows).
fw_require_sources
log "extracting proprietary firmware (searching all configured sources)"

VENDOR="qcom/x1p42100/ASUSTeK/zenbook-a14"
FW_BASE="/lib/firmware/updates/$VENDOR"   # 'updates' overrides linux-firmware, never clobbered
ESP_FW="$ESP/firmware/$VENDOR"            # DSP fw the slbounce boot chain loads (full vendor path)
install -d "$FW_BASE" "$ESP_FW"

while IFS='|' read -r fname esp; do
	fname="$(echo "$fname" | xargs)"; esp="$(echo "$esp" | xargs)"
	[ -n "$fname" ] && [ "${fname:0:1}" != "#" ] || continue
	# find by name across all sources (official driver folder / BSP / DriverStore)
	found="$(fw_find "$fname")" || { warn "MISSING from all sources: $fname (skipping)"; continue; }
	install_fw "$found" "$FW_BASE/$fname"
	[ "$esp" = "yes" ] && install -D -m644 "$found" "$ESP_FW/$fname" && ok "esp: firmware/$VENDOR/$fname"
done < "$MANIFEST"

echo
log "redistributable firmware (Wi-Fi WCN6855 / BT / GPU gen71500) ships in linux-firmware:"
for f in \
	ath11k/WCN6855/hw2.1/board-2.bin ath11k/WCN6855/hw2.1/amss.bin ath11k/WCN6855/hw2.1/m3.bin \
	qca/htbtfw20.tlv qcom/gen71500_gmu.bin qcom/gen71500_sqe.fw ; do
	if compgen -G "/lib/firmware/$f"'*' >/dev/null; then ok "have $f"; else warn "missing $f"; MISSING_REDIST=1; fi
done
if [ "${MISSING_REDIST:-0}" = 1 ]; then
	warn "update linux-firmware (these need a recent version):"
	warn "  apt install linux-firmware   # or clone gitlab.com/kernel-firmware/linux-firmware into /lib/firmware"
fi
ok "firmware stage done"
