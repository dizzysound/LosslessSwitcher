# analyze.py <run prefix> <rate> [source audio file] [skip_s]
# For a renderer run: (1) IO timeline gaps from <prefix>.cycles.txt, (2) null test of the monitor
# tap (what the HAL mixed for the device) against the Music tap, at the best integer lag,
# (3) optionally the Music tap against Apple's decode of the source (as in steady.py).
import sys, subprocess, tempfile, os, numpy as np
pre, rate = sys.argv[1], float(sys.argv[2])
src = sys.argv[3] if len(sys.argv) > 3 and sys.argv[3] != "-" else None
skip = float(sys.argv[4]) if len(sys.argv) > 4 else 0.0
tap = np.fromfile(pre + ".tap.f32", dtype=np.float32).reshape(-1, 2).astype(np.float64)
mon = np.fromfile(pre + ".mon.f32", dtype=np.float32).reshape(-1, 2).astype(np.float64)

cyc = np.loadtxt(pre + ".cycles.txt", ndmin=2)
st, n = cyc[:, 0], cyc[:, 1]
jumps = np.nonzero(np.abs(np.diff(st) - n[:-1]) > 0.5)[0]
print(f"cycles {len(cyc)}, frames {int(n.sum())}; sample-time discontinuities: {len(jumps)}")
cum = np.concatenate([[0], np.cumsum(n)])
for j in jumps[:12]:
    print(f"  after cycle {j} (frame {int(cum[j+1])}, {cum[j+1]/rate:.3f} s): expected +{int(n[j])}, got {st[j+1]-st[j]:+.0f}")

nz = np.nonzero(np.abs(tap[:, 0]) > 1e-6)[0]
if len(nz) == 0: print("tap is silent"); sys.exit()
first = nz[0]; start = max(first, int(skip * rate))
print(f"tap signal from frame {first} ({first/rate:.3f} s); analyzing from {start/rate:.3f} s")

# monitor vs tap: find the lag (monitor may trail the tap by some cycles)
seg = tap[start:start + int(rate), 0]
best = None
for lag in range(0, 8193):
    m = mon[start + lag:start + lag + len(seg), 0]
    if len(m) < len(seg): break
    r = np.max(np.abs(m - seg))
    if best is None or r < best[0]: best = (r, lag)
    if r == 0: break
r, lag = best
a = tap[start:len(mon) - lag]; b = mon[start + lag:start + lag + len(a)]
d = b - a
print(f"monitor vs tap: lag {lag} frames; compared {len(a)/rate:.2f} s; identical {np.mean(d == 0)*100:.4f}%; max |diff| {np.abs(d).max():.3e} = {np.abs(d).max()*2**23:.3f} LSB@24")
if np.any(d != 0):
    bad = np.nonzero(np.any(d != 0, axis=1))[0]
    print(f"  {len(bad)} differing frames; first at {(start+bad[0])/rate:.3f} s, last at {(start+bad[-1])/rate:.3f} s")
    g = np.dot(a.ravel(), b.ravel()) / np.dot(a.ravel(), a.ravel()); print(f"  monitor/tap gain {g:.9f}")

if src:
    tmp = tempfile.mktemp(suffix=".wav"); subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32", src, tmp], check=True)
    raw = open(tmp, "rb").read(); os.remove(tmp); i = raw.find(b"data"); nb = int.from_bytes(raw[i+4:i+8], "little")
    s = np.frombuffer(raw[i+8:i+8+nb], dtype=np.float32).reshape(-1, 2).astype(np.float64)
    R = int(rate)
    s0 = int(np.argmax(np.abs(s[:, 0]) > 1e-6)); win = s[s0:s0 + R, 0]; seg = tap[first:first + R * 5, 0]
    off = first + int(np.argmax(np.correlate(seg, win, "valid"))) - s0
    cs, ss = (off, 0) if off >= 0 else (0, -off); L = min(len(tap) - cs, len(s) - ss)
    a, b = tap[cs:cs + L], s[ss:ss + L]
    k = max(0, int(0.05 * rate) - ss, start - cs); a, b = a[k:], b[k:]
    d = a - b
    print(f"tap vs source: offset {off}, compared {len(a)/rate:.2f} s; max |diff| {np.abs(d).max()*2**23:.3f} LSB@24")
    g = np.dot(a.ravel(), b.ravel()) / np.dot(b.ravel(), b.ravel()); print(f"  gain {g:.9f} (1 - {1-g:.2e})")
    for bits in (16, 24):
        q = 2.0 ** (bits - 1)
        if np.all(np.round(b * q) == b * q):
            m = np.round(a * q) == np.round(b * q); print(f"  source is {bits}-bit: capture rounded to {bits}-bit matches {m.mean()*100:.4f}% ({(~m).sum()} samples differ)")
            break
    # dropouts: runs of exact zeros in the tap where the source is not silent
    z = (a[:, 0] == 0) & (np.abs(b[:, 0]) > 1e-4)
    print(f"  frames where tap is 0 but source isn't: {int(z.sum())}")
