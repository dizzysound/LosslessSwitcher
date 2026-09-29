# segcheck.py <run prefix> <rate>=<source file> [<rate>=<source file> ...]
# For each pipeline segment of a renderer run (from <prefix>.segments.txt), aligns the Music tap
# with Apple's decode of the source played at that rate and reports: how much of the segment has
# signal, dropouts (tap exactly 0 while the source isn't), exactness after rounding to the source's
# bit depth, and whether the monitor tap (our output as mixed by the HAL) equals the Music tap.
import sys, subprocess, tempfile, os, numpy as np
pre = sys.argv[1]
srcs = {float(a.split("=", 1)[0]): a.split("=", 1)[1] for a in sys.argv[2:]}
tap = np.fromfile(pre + ".tap.f32", dtype=np.float32).reshape(-1, 2).astype(np.float64)
mon = np.fromfile(pre + ".mon.f32", dtype=np.float32).reshape(-1, 2).astype(np.float64)
segs = [tuple(map(float, l.split())) for l in open(pre + ".segments.txt") if l.strip()]
bounds = [int(s[0]) for s in segs] + [len(tap)]
cache = {}
def decode(path):
    if path not in cache:
        tmp = tempfile.mktemp(suffix=".wav"); subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32", path, tmp], check=True)
        raw = open(tmp, "rb").read(); os.remove(tmp); i = raw.find(b"data"); n = int.from_bytes(raw[i+4:i+8], "little")
        cache[path] = np.frombuffer(raw[i+8:i+8+n], dtype=np.float32).reshape(-1, 2).astype(np.float64)
    return cache[path]
for k, (start, rate) in enumerate(segs):
    t = tap[bounds[k]:bounds[k + 1]]; m = mon[bounds[k]:bounds[k + 1]]; R = int(rate)
    nzi = np.flatnonzero(np.abs(t[:, 0]) > 0)
    print(f"segment {k+1}: {rate:.0f} Hz, {len(t)/rate:.2f} s, signal in {len(nzi)/max(len(t),1)*100:.1f}% of frames"
          + (f" (first at {nzi[0]/rate:.2f} s)" if len(nzi) else ""))
    if len(nzi) < R or rate not in srcs: continue
    s = decode(srcs[rate]); first = nzi[0]
    # align: locate 1 s of the tap (from 1 s after its first signal) in the source
    seg = t[first + R:first + 2 * R, 0]; ref = s[:R * 60, 0]  # tracks are played from the start
    nfft = 1 << int(np.ceil(np.log2(len(ref) + len(seg))))
    cc = np.fft.irfft(np.fft.rfft(ref, nfft) * np.conj(np.fft.rfft(seg, nfft)), nfft)[:len(ref) - len(seg)]
    pos = int(np.argmax(cc)); off = first + R - pos      # tap index of source frame 0
    # FFT cross-correlation of unnormalized audio can lock onto a loud passage elsewhere; if the
    # result isn't a sample match, search exactly for where 50 ms of the tap sits in the source.
    w = t[first + R:first + R + R // 20, 0]
    def err(o): p = first + R - o; y = s[p:p + len(w), 0]; return np.abs(w - y).max() if 0 <= p and len(y) == len(w) else 9.0
    if err(off) * 2**23 > 2:
        # candidates: source frames whose first sample matches w[0] within 2 LSB@24
        cand = np.flatnonzero(np.abs(s[:, 0] - w[0]) * 2**23 <= 2)
        best = min((first + R - p for p in cand), key=err, default=off)
        print(f"  (FFT alignment failed; exact search -> offset {best}, err {err(best) * 2**23:.2f} LSB)"); off = best
    cs, ss = (off, 0) if off >= 0 else (0, -off); L = min(len(t) - cs, len(s) - ss)
    a, b = t[cs:cs + L], s[ss:ss + L]
    k0 = max(0, int(0.05 * rate) - ss); a, b = a[k0:], b[k0:]  # skip the first 50 ms of the track
    live = np.flatnonzero(np.abs(a[:, 0]) > 0); a, b = a[live[0]:], b[live[0]:]
    drop = (a[:, 0] == 0) & (np.abs(b[:, 0]) > 1e-4)
    print(f"  aligned to source frame {ss + k0 + live[0]} ({(ss + k0 + live[0])/rate:.2f} s into the track), compared {len(a)/rate:.2f} s; dropout frames {int(drop.sum())}")
    ok = ~drop
    g = np.dot(a[ok].ravel(), b[ok].ravel()) / np.dot(b[ok].ravel(), b[ok].ravel())
    print(f"  gain 1 - {1-g:.2e}; max |diff| {np.abs(a[ok]-b[ok]).max()*2**23:.2f} LSB@24")
    for bits in (16, 24):
        q = 2.0 ** (bits - 1)
        if np.all(np.round(b * q) == b * q):
            e = np.round(a[ok] * q) == np.round(b[ok] * q)
            print(f"  source is {bits}-bit: tap rounded to {bits}-bit matches {e.mean()*100:.4f}% ({(~e).sum()} samples differ)"); break
    # monitor vs tap within the segment
    best = None
    for lag in range(0, 4097):
        x = t[first + R:first + 2 * R, 0]; y = m[first + R + lag:first + 2 * R + lag, 0]
        if len(y) < len(x): break
        r = np.max(np.abs(x - y))
        if best is None or r < best[0]: best = (r, lag)
        if r == 0: break
    lag = best[1]; x = t[first:len(m) - lag]; y = m[first + lag:first + lag + len(x)]
    print(f"  monitor vs tap: lag {lag}, identical {np.mean(x == y)*100:.4f}%")
