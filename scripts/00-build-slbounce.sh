#!/usr/bin/env bash
# Stage 0 — pull + build the slbounce + qebspil EFI drivers, copy them into
# config/slbounce/ as *aa64.efi (where 03-setup-el2-boot.sh installs them from).
#   slbounce  https://github.com/TravMurav/slbounce   (EL2 Secure-Launch bounce)
#   qebspil   https://github.com/stephan-gh/qebspil    (pre-boots ADSP/CDSP in EL1)
# Build is native arm64 (run on the A14). gnu-efi/libfdt come in as submodules.
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
load_env || true   # no root needed to build

for t in git make gcc; do command -v "$t" >/dev/null || die "missing build tool: $t (apt install build-essential git)"; done

OUT="$HERE/config/slbounce"; mkdir -p "$OUT"
BUILD="${SLBOUNCE_BUILD:-$HOME/zenbook-a14-slbounce-build}"; mkdir -p "$BUILD"

build_one() {
	local name="$1" repo="$2" want="$3" dest="$4" efi
	local d="$BUILD/$name"
	if [ -d "$d/.git" ]; then
		log "$name: updating $d"; git -C "$d" pull --ff-only 2>/dev/null || true
	else
		log "$name: cloning $repo"; git clone --recurse-submodules "$repo" "$d"
	fi
	( cd "$d" && git submodule update --init --recursive 2>/dev/null || true; make )
	efi="$(find "$d" -name "$want" -type f 2>/dev/null | head -1)"
	if [ -z "$efi" ]; then
		warn "$name: did not find '$want'. Produced EFI files:"
		find "$d" -name '*.efi' -type f 2>/dev/null | sed 's/^/    /'
		die "$name build did not yield $want — check its README for the right target"
	fi
	install -m644 "$efi" "$dest"; ok "$name: $(basename "$efi") -> ${dest#"$HERE/"} ($(stat -c %s "$dest") B)"
}

build_one slbounce https://github.com/TravMurav/slbounce.git slbounce.efi "$OUT/slbounceaa64.efi"
build_one qebspil  https://github.com/stephan-gh/qebspil.git  qebspilaa64.efi  "$OUT/qebspilaa64.efi"

ok "slbounce + qebspil built into config/slbounce/ (03-setup-el2-boot.sh installs them)"
