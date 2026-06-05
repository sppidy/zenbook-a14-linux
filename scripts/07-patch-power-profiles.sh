#!/usr/bin/env bash
# Stage 7 — patch power-profiles-daemon for the A14's DT platform-profile.
#
# The A14 EC exposes its platform profile via the NEW /sys/class/platform-profile/
# interface (the A14 is a DT system — there is no ACPI platform_profile), and adds
# a 'max-power' choice above 'performance'. Upstream power-profiles-daemon only
# reads the legacy /sys/firmware/acpi/platform_profile path and has no max-power
# profile, so it sees nothing on the A14. This builds PPD with the A14 patch:
#   - fall back to /sys/class/platform-profile/<dev>/{profile,choices}
#   - add the PPD_PROFILE_MAX_POWER profile + map it to the EC's 'max-power'
#
# The kernel side (platform_profile on non-ACPI + the max-power option) is already
# in the a14/jg-qcom-7.1-rc-6 branch, so by this point /sys/class/platform-profile
# exists. Based on github.com/sppidy/asus-zenbook-a14-ec patches (extended with
# the max-power handling the daemon needs to actually compile + work).
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
need_root; load_env

PPD_REPO="${PPD_REPO:-https://gitlab.freedesktop.org/upower/power-profiles-daemon.git}"
PPD_BASE="${PPD_BASE:-5b4994c8a91290481bef87a5bae95391d0ec677f}"   # Release 0.30
PPD_BUILD="${PPD_BUILD:-$HOME/zenbook-a14-ppd-build}"
PATCH="$HERE/config/power-profiles-daemon/0001-ppd-class-platform-profile-fallback.patch"

[ -f "$PATCH" ] || die "missing $PATCH"

# Nothing to do if there's no class platform-profile (wrong kernel / not an A14).
if [ ! -d /sys/class/platform-profile ] || [ -z "$(ls -A /sys/class/platform-profile 2>/dev/null)" ]; then
	warn "/sys/class/platform-profile is empty — boot the a14 kernel (EC platform_profile driver) first, then re-run this stage"
fi

# --- build deps --------------------------------------------------------------
if command -v apt-get >/dev/null; then
	DEBIAN_FRONTEND=noninteractive apt-get install -y \
		build-essential meson ninja-build git pkg-config \
		libglib2.0-dev libgudev-1.0-dev libpolkit-gobject-1-dev systemd-dev \
		python3 python-is-python3 \
		|| warn "apt install of PPD build deps failed — install them manually"
else
	warn "non-apt distro: install meson/ninja/gcc + glib/gudev/polkit-gobject/systemd dev yourself"
fi

# --- clone pinned + apply the A14 patch --------------------------------------
if [ -d "$PPD_BUILD/.git" ]; then git -C "$PPD_BUILD" fetch origin 2>/dev/null || true
else git clone "$PPD_REPO" "$PPD_BUILD"; fi
git -C "$PPD_BUILD" checkout -q "$PPD_BASE" 2>/dev/null || die "cannot checkout PPD base $PPD_BASE"
git -C "$PPD_BUILD" checkout -- . 2>/dev/null || true
git -C "$PPD_BUILD" apply "$PATCH" 2>/dev/null || git -C "$PPD_BUILD" apply --3way "$PATCH" \
	|| die "PPD patch did not apply onto $PPD_BASE — rebase $(basename "$PATCH")"
ok "applied A14 platform-profile patch (class fallback + max-power)"

# --- build + install over the distro PPD -------------------------------------
( cd "$PPD_BUILD" && rm -rf _build \
	&& meson setup _build --prefix=/usr -Dtests=false -Dgtk_doc=false -Dmanpage=disabled \
	&& meson compile -C _build ) || die "PPD build failed"
meson install --no-rebuild -C "$PPD_BUILD/_build" || die "PPD install failed"
ldconfig

# --- restart + verify --------------------------------------------------------
systemctl daemon-reload
systemctl restart power-profiles-daemon 2>/dev/null || true
( sleep 1
  if powerprofilesctl 2>/dev/null | grep -q 'platform_profile'; then
	ok "power-profiles-daemon active — profiles: $(powerprofilesctl list 2>/dev/null | grep -oE 'performance|balanced|power-saver' | tr '\n' ' ')"
  else
	warn "powerprofilesctl not reporting platform_profile — check 'systemctl status power-profiles-daemon' + /sys/class/platform-profile/"
  fi )

ok "power-profiles-daemon stage done."
log "switch profiles with:  powerprofilesctl set performance   (GNOME power menu also uses this)"
