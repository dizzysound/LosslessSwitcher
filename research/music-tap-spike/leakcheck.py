# leakcheck.py <run prefix> <old track file> <rate> <delay ms>: for an --auto switch away from a
# track played at its own rate, finds where that track ends in the Music tap (b) and where the
# renderer's output went silent (m, in the output = tap delayed by D). Output frames taken from the
# tap after b are the new track's start at the wrong rate reaching the DAC ("leak").
import sys, subprocess, tempfile, os, numpy as np
pre, src, R, dms = sys.argv[1], sys.argv[2], int(sys.argv[3]), float(sys.argv[4])
D = int(dms / 1000 * R)
tmp = tempfile.mktemp(suffix=".wav"); subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32", src, tmp], check=True)
raw = open(tmp, "rb").read(); os.remove(tmp); i = raw.find(b"data"); n = int.from_bytes(raw[i+4:i+8], "little")
s = np.frombuffer(raw[i+8:i+8+n], dtype=np.float32).reshape(-1, 2).astype(np.float64)
tap = np.fromfile(pre + ".tap.f32", dtype=np.float32).reshape(-1, 2).astype(np.float64)
out = np.fromfile(pre + ".out.f32", dtype=np.float32).reshape(-1, 2).astype(np.float64)
segs = [(int(float(l.split()[0])), float(l.split()[1])) for l in open(pre + ".segments.txt") if l.strip()]
for k, (st, rate) in enumerate(segs):
    if rate != R: continue
    en = segs[k + 1][0] if k + 1 < len(segs) else len(tap)
    t = tap[st:en]
    # the old track's last 3 s: where do they sit in this segment?
    w = s[-3 * R:-2 * R, 0]
    cand = np.flatnonzero(np.abs(t[:, 0] - w[0]) * 2**23 <= 2)
    ok = [c for c in cand if c + len(w) <= len(t) and np.abs(t[c:c + len(w), 0] - w).max() * 2**23 <= 2]
    if not ok: continue
    b = ok[0] + 3 * R   # tap index (in segment) just past the old track's last frame
    o = out[st:en]
    nz = np.flatnonzero(np.abs(o[:, 0]) > 0)
    last_out = nz[nz < b + D + R][-1] if len(nz) else -1  # last nonzero output before the long mute
    src_of_last = last_out - D                            # tap frame it came from
    print(f"segment {k+1} ({rate:.0f} Hz): old track ends at tap frame {b} ({b/R:.3f} s into the segment)")
    print(f"  last nonzero output frame {last_out} = tap frame {src_of_last} -> {'LEAK of %d frames (%.1f ms) of the next track' % (src_of_last - b + 1, (src_of_last - b + 1) / R * 1000) if src_of_last >= b else 'no leak; output stopped %.1f ms before the old track ended' % ((b - 1 - src_of_last) / R * 1000)}")
    # output before the mute == tap delayed by D?
    a = o[D:last_out + 1]; c = t[:last_out + 1 - D]
    print(f"  output == tap delayed {D} frames up to the mute: {np.array_equal(a, c)}")
