#!/usr/bin/env bash
# Stage 4 — config: iris blacklist + optional camera-ALS auto-brightness daemon.
source "$(cd "$(dirname "$0")/.." && pwd)/lib/common.sh"
need_root; load_env

# iris HW video codec is unreachable on the A14 and resets the SoC if poked.
install -D -m644 "$HERE/config/blacklist-qcom-iris.conf" /etc/modprobe.d/blacklist-qcom-iris.conf
ok "iris blacklisted (/etc/modprobe.d/blacklist-qcom-iris.conf)"
modprobe -r qcom_iris 2>/dev/null || true

# Optional: camera-ALS -> auto-brightness daemon (needs python3 + opencv/v4l2 + the SSC).
if [ -d "$HERE/config/autobright" ]; then
	install -D -m755 "$HERE/config/autobright/autobright.py"  /usr/local/bin/autobright.py
	[ -f "$HERE/config/autobright/color_stream.py" ] && install -D -m755 "$HERE/config/autobright/color_stream.py" /usr/local/bin/color_stream.py
	install -D -m644 "$HERE/config/autobright/autobright.service" /etc/systemd/system/autobright.service
	systemctl daemon-reload
	systemctl enable autobright.service >/dev/null 2>&1 || true
	ok "auto-brightness daemon installed (systemctl status autobright)"
else
	log "auto-brightness daemon not bundled — skipping (optional)"
fi
ok "config stage done"
