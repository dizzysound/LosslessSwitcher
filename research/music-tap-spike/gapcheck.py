# gapcheck.py <run prefix> <rate> <track A file> <track B file>: checks that the last pipeline
# segment of a run equals the end of track A followed directly by the start of track B
# (Apple's decode of each, concatenated), i.e. that a gapless transition came through intact.
import sys, subprocess, tempfile, os, numpy as np
pre, R, fa, fb = sys.argv[1], int(sys.argv[2]), sys.argv[3], sys.argv[4]
def decode(p):
    tmp = tempfile.mktemp(suffix=".wav"); subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32", p, tmp], check=True)
    raw = open(tmp, "rb").read(); os.remove(tmp); i = raw.find(b"data"); n = int.from_bytes(raw[i+4:i+8], "little")
    return np.frombuffer(raw[i+8:i+8+n], dtype=np.float32).reshape(-1, 2).astype(np.float64)
A, B = decode(fa), decode(fb)
ref = np.concatenate([A[-R * 40:], B[:R * 60]]); boundary = R * 40   # index of B's frame 0 in ref
tap = np.fromfile(pre + ".tap.f32", dtype=np.float32).reshape(-1, 2).astype(np.float64)
segs = [int(float(l.split()[0])) for l in open(pre + ".segments.txt") if l.strip()]
t = tap[segs[-1]:]
first = int(np.flatnonzero(np.abs(t[:, 0]) > 0)[0])
w = t[first + R:first + R + R // 20, 0]
cand = np.flatnonzero(np.abs(ref[:, 0] - w[0]) * 2**23 <= 2)
def err(p): y = ref[p:p + len(w), 0]; return np.abs(w - y).max() if len(y) == len(w) else 9.0
p = min(cand, key=err); off = first + R - p           # tap index of ref frame 0
print(f"aligned: err {err(p) * 2**23:.2f} LSB; boundary at tap frame {off + boundary} ({(off + boundary) / R:.2f} s into the segment)")
cs = max(off, 0, first); a = t[cs:]; b = ref[cs - off:cs - off + len(a)]; a = a[:len(b)]
d = np.abs(a - b).max(axis=1) * 2**23
q = 2.0 ** 23; m = np.round(a * q) == np.round(b * q)
bi = off + boundary - cs
print(f"compared {len(a) / R:.2f} s ({bi / R:.2f} s of A's end, {(len(a) - bi) / R:.2f} s of B); max err {d.max():.2f} LSB@24; 24-bit match {m.mean() * 100:.4f}%")
for lo, hi, label in [(bi - R // 10, bi + R // 10, "+-100 ms around the boundary"), (bi - R, bi + R, "+-1 s")]:
    lo, hi = max(lo, 0), min(hi, len(d))
    print(f"  {label}: max err {d[lo:hi].max():.2f} LSB, frames > 1 LSB: {(d[lo:hi] > 1).sum()}, tap zeros where ref isn't: {int(((a[lo:hi, 0] == 0) & (np.abs(b[lo:hi, 0]) > 1e-4)).sum())}")
print(f"  whole: frames > 1 LSB: {(d > 1).sum()}, dropouts: {int(((a[:, 0] == 0) & (np.abs(b[:, 0]) > 1e-4)).sum())}")
