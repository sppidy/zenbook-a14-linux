#!/usr/bin/env bash
# zenbook-a14-linux — top-level installer.
# Runs the stages in order. Each stage is also runnable on its own.
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/lib/common.sh"

need_root
load_env
assert_a14

cat <<EOF

  ASUS Zenbook A14 (x1p42100) — Linux installer
  ---------------------------------------------
  root UUID   : $ROOT_UUID
  ESP         : $ESP   (machine-id $MACHINE_ID)
  kernel      : $KERNEL_BRANCH  ->  $KERNEL_SRC
  firmware    : ${BSP_DIR:-${WINDOWS_MOUNT:-<unset: edit install.env>}}

EOF
read -rp "Proceed? [y/N] " a; [ "${a,,}" = y ] || die "aborted"

"$HERE/scripts/00-build-slbounce.sh"
"$HERE/scripts/01-extract-firmware.sh"
"$HERE/scripts/02-install-kernel.sh"
"$HERE/scripts/03-setup-el2-boot.sh"
"$HERE/scripts/04-apply-config.sh"
"$HERE/scripts/05-setup-ssc-sensors.sh"
"$HERE/scripts/06-setup-iio-sensor-proxy.sh"
"$HERE/scripts/07-patch-power-profiles.sh"

cat <<EOF

$(ok "Install complete.")
  Reboot and pick the 'EL2-JG' entry (it is the default).
  After boot, verify:
    uname -r            # 7.1.0-rc6-a14-x1p-jg-el2+
    ls /dev/kvm         # EL2 live
    cat /sys/class/hwmon/*/fan1_input        # EC fan
    systemctl is-active hexagonrpcd          # SSC up
    journalctl --user -u autobright -f       # camera-ALS streaming (lux/cct)
EOF
