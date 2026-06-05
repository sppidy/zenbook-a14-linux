#!/usr/bin/env python3
"""
autobright — automatic screen brightness from the A14's SSC camera ALS.

Streams the Snapdragon Sensor Core 'color' sensor (the qsh_camera ov02c10
ambient-light function: lux + CCT + CIE) over QMI/QRTR and drives the eDP
backlight (dp_aux_backlight) via brightnessctl, with EMA smoothing + a deadband
so it doesn't flicker. Robust for running as a service: waits for the SNS
service (hexagonrpcd) to come up, and reconnects if the stream stalls.

Tunable via env vars (defaults calibrated toward a dimmer indoor preference):
  AB_LUX_MIN=60     lux at/below this -> floor brightness
  AB_LUX_MAX=2000   lux at/above this -> full brightness
  AB_BL_MIN_PCT=0.12  floor brightness as fraction of max (never black)
  AB_RATE=5         ALS sample rate (Hz)
  AB_EMA=0.15       smoothing 0..1 (higher = snappier)
  AB_DEADBAND_PCT=0.015  min change (fraction of max) before applying
Make it dimmer overall: raise AB_LUX_MIN.  Hit full brightness sooner: lower AB_LUX_MAX.
"""
import sys, os, time, math, subprocess, signal
sys.path.insert(0, "/home/spidy/a14-re/presence-re")
import sns_probe as S
import color_stream as C

BL_DEV  = "dp_aux_backlight"
BL_PATH = "/sys/class/backlight/" + BL_DEV

def env_f(k, d): return float(os.environ.get(k, d))

LUX_MIN      = env_f("AB_LUX_MIN", 60)
LUX_MAX      = env_f("AB_LUX_MAX", 2000)
BL_MIN_PCT   = env_f("AB_BL_MIN_PCT", 0.12)
RATE         = env_f("AB_RATE", 5)
EMA_A        = env_f("AB_EMA", 0.15)
DEADBAND_PCT = env_f("AB_DEADBAND_PCT", 0.015)

def read_max():
    with open(BL_PATH + "/max_brightness") as f:
        return int(f.read().strip())

def lux_to_bl(lux, bl_max, bl_min):
    a, b = math.log10(LUX_MIN), math.log10(LUX_MAX)
    t = (math.log10(max(lux, 0.05)) - a) / (b - a)
    t = max(0.0, min(1.0, t))
    return int(round(bl_min + t * (bl_max - bl_min)))

def set_bl(v, bl_max, bl_min):
    v = max(bl_min, min(bl_max, int(v)))
    subprocess.run(["brightnessctl", "-d", BL_DEV, "set", str(v)],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    return v

def wait_for_sns(run):
    while run[0]:
        node, port = S.resolve_sns()
        if node is not None:
            return node, port
        print("autobright: waiting for SNS service (hexagonrpcd)...", flush=True)
        time.sleep(5)
    return None, None

def main():
    bl_max   = read_max()
    bl_min   = int(bl_max * BL_MIN_PCT)
    deadband = max(1, int(bl_max * DEADBAND_PCT))
    print(f"autobright: BL[{bl_min}..{bl_max}] lux[{LUX_MIN:.0f}..{LUX_MAX:.0f}] "
          f"ema={EMA_A} deadband={deadband} rate={RATE:.0f}Hz", flush=True)
    run = [True]
    for sig in (signal.SIGTERM, signal.SIGINT):
        signal.signal(sig, lambda *a: run.__setitem__(0, False))

    ema = cur = None
    while run[0]:
        node, port = wait_for_sns(run)
        if node is None:
            break
        sock, _ = S.create_qrtr_socket()
        S.sns_send(sock, (node, port), C.build_std_cfg(C.SL, C.SH, RATE, S.PROC_APSS), txn_id=3)
        last_event = time.time()
        while run[0]:
            got = False
            for sl, sh, events in S.sns_recv(sock, 2.0):
                for evt in events:
                    if evt['msg_id'] != C.SNS_STD_SENSOR_EVENT:
                        continue
                    f = C.floats_of(evt['payload'])
                    if not f:
                        continue
                    got = True
                    lux = f[0]
                    cct = f[1] if len(f) > 1 else 0.0
                    ema = lux if ema is None else (EMA_A * lux + (1 - EMA_A) * ema)
                    tgt = lux_to_bl(ema, bl_max, bl_min)
                    if cur is None or abs(tgt - cur) >= deadband:
                        cur = set_bl(tgt, bl_max, bl_min)
                        print(f"  lux={ema:6.1f} cct={cct:5.0f}K -> {cur:4d}/{bl_max} "
                              f"({100*cur//bl_max:3d}%)", flush=True)
            if got:
                last_event = time.time()
            elif time.time() - last_event > 15:
                print("autobright: stream stalled, reconnecting...", flush=True)
                break
        try: sock.close()
        except Exception: pass
    print("autobright: stopped", flush=True)

if __name__ == "__main__":
    main()
