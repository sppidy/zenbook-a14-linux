#!/usr/bin/env bash
# Stage 2 — build + install the kernel (native arm64 on the A14 is fine).
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
need_root; load_env

if [ ! -d "$KERNEL_SRC/.git" ]; then
	log "cloning $KERNEL_REPO ($KERNEL_BRANCH) -> $KERNEL_SRC"
	git clone --depth 1 --branch "$KERNEL_BRANCH" "$KERNEL_REPO" "$KERNEL_SRC"
else
	log "kernel source present at $KERNEL_SRC (using as-is; git pull yourself to update)"
fi

cd "$KERNEL_SRC"
cp "$HERE/config/kernel.config" .config
make ARCH=arm64 olddefconfig >/dev/null

log "building Image + modules + dtbs (-j$JOBS) — this takes a while"
make ARCH=arm64 -j"$JOBS" Image modules dtbs

KERNEL_RELEASE="$(make -s ARCH=arm64 kernelrelease)"
log "kernelrelease: $KERNEL_RELEASE"
make ARCH=arm64 modules_install >/dev/null
ok "modules installed -> /lib/modules/$KERNEL_RELEASE"

# stash values for the next stage
cat > "$HERE/config/.build.env" <<EOF
KERNEL_RELEASE="$KERNEL_RELEASE"
KERNEL_SRC="$KERNEL_SRC"
EOF
ok "kernel stage done"
