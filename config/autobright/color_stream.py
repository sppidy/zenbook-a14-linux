#!/usr/bin/env python3
"""Stream the SSC 'color' (camera ALS) sensor — reuses sns_probe primitives.
Sends SNS_STD_SENSOR_CONFIG (513) and decodes std sensor data events (1025)."""
import sys, time, struct
sys.path.insert(0, "/home/spidy/a14-re/presence-re")
import sns_probe as S

# 'color' SUID  (printed 0x<high><low>): high=0x81c0e47fa02563a0 low=0x774866c76d059c74
SL = 0x774866c76d059c74
SH = 0x81c0e47fa02563a0

SNS_STD_SENSOR_CONFIG = 513
SNS_STD_SENSOR_EVENT  = 1025
SNS_STD_SENSOR_PHYS_CONFIG_EVENT = 1026

def build_std_cfg(sl, sh, rate, proc, delivery=0, msgid=SNS_STD_SENSOR_CONFIG):
    suid = S.pb_field_fixed64(1, sl) + S.pb_field_fixed64(2, sh)
    susp = S.pb_field_varint(1, proc) + S.pb_field_varint(2, delivery)
    inner = S.pb_field_float(1, rate)            # sns_std_sensor_config { sample_rate=1 }
    request = S.pb_field_bytes(2, inner)
    return (S.pb_field_msg(1, suid) + S.pb_field_fixed32(2, msgid)
          + S.pb_field_msg(3, susp) + S.pb_field_msg(4, request))

def floats_of(pl):
    out = []
    for fn, wt, v in S.pb_decode_fields(pl):
        if fn == 1 and wt == 2:           # packed repeated float
            for i in range(0, len(v) - 3, 4):
                out.append(struct.unpack('<f', v[i:i+4])[0])
        elif fn == 1 and wt == 5:
            out.append(struct.unpack('<f', struct.pack('<I', v))[0])
    return out

def main():
    rate = float(sys.argv[1]) if len(sys.argv) > 1 else 5.0
    dur  = float(sys.argv[2]) if len(sys.argv) > 2 else 12.0
    node, port = S.resolve_sns()
    print(f"SNS node={node} port={port}  proc=APSS({S.PROC_APSS})")
    sock, local = S.create_qrtr_socket()
    S.sns_send(sock, (node, port), build_std_cfg(SL, SH, rate, S.PROC_APSS), txn_id=3)
    print(f"=== color/ALS stream: cfg sample_rate={rate}Hz for {dur}s ===")
    deadline = time.time() + dur
    n = 0
    while time.time() < deadline:
        for sl, sh, events in S.sns_recv(sock, 2.0):
            for evt in events:
                mid, pl = evt['msg_id'], evt['payload']
                if mid == SNS_STD_SENSOR_EVENT:
                    print(f"  [{n}] DATA floats={[round(x,2) for x in floats_of(pl)]} ts={evt['timestamp']}")
                    n += 1
                elif mid == S.SNS_STD_ERROR_EVENT:
                    print(f"  ERROR_EVENT payload={pl.hex()}")
                elif mid == SNS_STD_SENSOR_PHYS_CONFIG_EVENT:
                    print(f"  PHYS_CONFIG floats={[round(x,2) for x in floats_of(pl)]}")
                else:
                    print(f"  evt msg_id={mid} len={len(pl)} {pl[:24].hex()}")
    print(f"  total data events: {n}")
    sock.close()

if __name__ == "__main__":
    main()
