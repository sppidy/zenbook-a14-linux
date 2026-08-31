#!/usr/bin/env bash
# Stage 1 — firmware.
#   * proprietary Qualcomm/ASUS blobs: extracted from YOUR Windows (per manifest)
#   * UX3407QA Wi-Fi: Windows WLAN firmware + patched linux-firmware board DB
#   * redistributable BT/GPU: from linux-firmware (installed by your distro)
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
need_root; load_env

for tool in git python3 sha256sum zstd; do
	command -v "$tool" >/dev/null || die "missing required command: $tool"
done

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
log "installing UX3407QA WCN6855/WCN6885 Wi-Fi firmware and board data"

WIFI_VENDOR="ath11k/WCN6855/hw2.1"
WIFI_BASE="/lib/firmware/updates/$WIFI_VENDOR"
WIFI_BOARD_ZST="$WIFI_BASE/board-2.bin.zst"
WIFI_BOARD_RAW="$WIFI_BASE/board-2.bin"
WIFI_ENCODER_REPO="https://github.com/qualcomm/qca-swiss-army-knife.git"
WIFI_ENCODER_COMMIT="6df4dae3e2f5e4c2903f3cafd40996fc1b3639ce"
WIFI_ENCODER_SHA256="4a2181d16d6ff35d60773b75aaa1bbe349afea7f03d4d2d97a596b81636a9e87"
WIFI_NAMES=(
	"bus=pci,vendor=17cb,device=1103,subsystem-vendor=14cd,subsystem-device=950a,qmi-chip-id=18,qmi-board-id=255,variant=UX3407Q"
	"bus=pci,vendor=17cb,device=1103,subsystem-vendor=14cd,subsystem-device=950a,qmi-chip-id=18,qmi-board-id=255"
	"bus=pci,vendor=17cb,device=1103,subsystem-vendor=14cd,subsystem-device=950a,qmi-chip-id=2,qmi-board-id=255,variant=UX3407Q"
	"bus=pci,vendor=17cb,device=1103,subsystem-vendor=14cd,subsystem-device=950a,qmi-chip-id=2,qmi-board-id=255"
)

wifi_board_has_names() {
	local board="$1" name
	[ -f "$board" ] || return 1
	for name in "${WIFI_NAMES[@]}"; do
		grep -aFq -- "$name" "$board" || return 1
	done
}

wifi_tmp="$(mktemp -d /tmp/zenbook-a14-wifi.XXXXXX)"
cleanup_wifi_tmp() {
	case "$wifi_tmp" in
		/tmp/zenbook-a14-wifi.*) rm -r -- "$wifi_tmp" ;;
	esac
}
trap cleanup_wifi_tmp EXIT

wifi_amss="$(fw_find wlanfw20.mbn)" || die "missing Windows WLAN firmware: wlanfw20.mbn"
wifi_source="$(dirname "$wifi_amss")"
for mapping in "wlanfw20.mbn:amss.bin" "m3.bin:m3.bin" "regdb.bin:regdb.bin"; do
	source_name="${mapping%%:*}"
	destination_name="${mapping#*:}"
	[ -f "$wifi_source/$source_name" ] ||
		die "Windows WLAN driver is incomplete: missing $source_name beside $wifi_amss"
	install_fw "$wifi_source/$source_name" "$WIFI_BASE/$destination_name"
done

wifi_board_elf="$(find "$wifi_source" -maxdepth 1 \
	-iname 'bdwlan_wcn685x_2p1_*UX3407Q*.elf' -type f -print -quit 2>/dev/null)"
if [ -z "$wifi_board_elf" ]; then
	wifi_board_elf="$(fw_find_glob 'bdwlan_wcn685x_2p1_*UX3407Q*.elf')" || true
fi

# Firmware loading tries every raw path before any compressed fallback. A raw
# distro board-2.bin therefore shadows an otherwise-correct updates/*.zst.
# Always materialize a validated raw override.
if wifi_board_has_names "$WIFI_BOARD_RAW"; then
	ok "Wi-Fi board DB: valid raw UX3407Q override already installed"
elif [ -f "$WIFI_BOARD_ZST" ]; then
	zstd -q -d -f "$WIFI_BOARD_ZST" -o "$wifi_tmp/board-2.from-updates.bin"
	if wifi_board_has_names "$wifi_tmp/board-2.from-updates.bin"; then
		install_fw "$wifi_tmp/board-2.from-updates.bin" "$WIFI_BOARD_RAW"
		ok "Wi-Fi board DB: materialized raw override from validated board-2.bin.zst"
	fi
fi

if ! wifi_board_has_names "$WIFI_BOARD_RAW"; then
	[ -n "$wifi_board_elf" ] ||
		die "missing UX3407Q Wi-Fi board ELF in the Windows WLAN driver"

	base_board=""
	for candidate in \
		/lib/firmware/ath11k/WCN6855/hw2.1/board-2.bin \
		/lib/firmware/ath11k/WCN6855/hw2.0/board-2.bin; do
		if [ -f "$candidate" ] || [ -f "$candidate.zst" ]; then
			base_board="$candidate"
			break
		fi
	done
	[ -n "$base_board" ] ||
		die "linux-firmware WCN6855 base board-2.bin(.zst) is missing"
	if [ -f "$base_board" ]; then
		install -m644 "$base_board" "$wifi_tmp/board-2.bin"
	else
		zstd -q -d -f "$base_board.zst" -o "$wifi_tmp/board-2.bin"
	fi

	encoder_tree="$wifi_tmp/qca-swiss-army-knife"
	git init -q "$encoder_tree"
	git -C "$encoder_tree" remote add origin "$WIFI_ENCODER_REPO"
	git -C "$encoder_tree" fetch -q --depth=1 origin "$WIFI_ENCODER_COMMIT"
	git -C "$encoder_tree" checkout -q FETCH_HEAD -- tools/scripts/ath11k/ath11k-bdencoder
	encoder="$encoder_tree/tools/scripts/ath11k/ath11k-bdencoder"
	encoder_digest="$(sha256sum "$encoder")"; encoder_digest="${encoder_digest%% *}"
	[ "$encoder_digest" = "$WIFI_ENCODER_SHA256" ] ||
		die "downloaded ath11k-bdencoder failed its pinned SHA-256 check"

	python3 "$encoder" -a "$wifi_tmp/board-2.bin" "$wifi_board_elf" \
		"${WIFI_NAMES[@]}" >/dev/null
	wifi_board_has_names "$wifi_tmp/board-2.bin" ||
		die "patched Wi-Fi board DB does not contain every required UX3407Q name"
	install_fw "$wifi_tmp/board-2.bin" "$WIFI_BOARD_RAW"
	zstd -q -f "$wifi_tmp/board-2.bin" -o "$WIFI_BOARD_ZST"
	chmod 0644 "$WIFI_BOARD_ZST"
	ok "Wi-Fi board DB: patched for UX3407Q chip IDs 2 and 18"
fi

echo
log "redistributable Bluetooth/GPU firmware ships in linux-firmware:"
for f in \
	qca/htbtfw20.tlv qcom/gen71500_gmu.bin qcom/gen71500_sqe.fw ; do
	if compgen -G "/lib/firmware/$f"'*' >/dev/null; then ok "have $f"; else warn "missing $f"; MISSING_REDIST=1; fi
done
if [ "${MISSING_REDIST:-0}" = 1 ]; then
	warn "update linux-firmware (these need a recent version):"
	warn "  apt install linux-firmware   # or clone gitlab.com/kernel-firmware/linux-firmware into /lib/firmware"
fi
ok "firmware stage done"
