# steady.py <capture.f32> <src> <rate> [skip_ms]: align (try both methods, keep the smaller residual),
# skip the first skip_ms of the track, then report exactness and the implied gain.
import numpy as np, subprocess, tempfile, os, sys
capf, srcf, rate = sys.argv[1], sys.argv[2], float(sys.argv[3]); skip = float(sys.argv[4]) if len(sys.argv) > 4 else 50
cap = np.fromfile(capf, dtype=np.float32).reshape(-1, 16)[:, :2].astype(np.float64)
tmp = tempfile.mktemp(suffix=".wav"); subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32", srcf, tmp], check=True)
raw = open(tmp, "rb").read(); os.remove(tmp); i = raw.find(b"data"); n = int.from_bytes(raw[i+4:i+8], "little")
src = np.frombuffer(raw[i+8:i+8+n], dtype=np.float32).reshape(-1, 2).astype(np.float64)
R = int(rate); first = int(np.argmax(np.abs(cap[:, 0]) > 1e-6))
cands = []
s0 = int(np.argmax(np.abs(src[:, 0]) > 1e-6)); win = src[s0:s0 + R, 0]; seg = cap[first:first + R * 5, 0]
if len(seg) > len(win): cands.append(first + int(np.argmax(np.correlate(seg, win, "valid"))) - s0)
seg = cap[first + R:first + int(R * 1.5), 0]; ref = src[:R * 60, 0]; nfft = 1 << int(np.ceil(np.log2(len(ref) + len(seg))))
cc = np.fft.irfft(np.fft.rfft(ref, nfft) * np.conj(np.fft.rfft(seg, nfft)), nfft)[:len(ref) - len(seg)]
cands.append(first + R - int(np.argmax(cc)))
best = None
for off in cands:
    cs, ss = (off, 0) if off >= 0 else (0, -off); L = min(len(cap) - cs, len(src) - ss)
    if L <= 0: continue
    a, b = cap[cs:cs + L], src[ss:ss + L]; r = np.sqrt(np.mean((a - b) ** 2))
    if best is None or r < best[0]: best = (r, off, a, b, ss)
r, off, a, b, ss = best
k = max(0, int(skip / 1000 * rate) - ss); a, b = a[k:], b[k:]
d = a - b
print(f"offset {off}, compared {len(a)/rate:.1f} s (skipping first {skip:.0f} ms of the track)")
print(f"float identical {np.mean(d == 0)*100:.3f}%, max |diff| {np.abs(d).max()*2**23:.3f} LSB@24")
g = np.dot(a.ravel(), b.ravel()) / np.dot(b.ravel(), b.ravel()); print(f"gain {g:.9f} (1 - {1-g:.2e})")
for bits in (16, 24):
    q = 2.0 ** (bits - 1); exact = np.all(np.round(b * q) == b * q)
    if exact:
        m = np.round(a * q) == np.round(b * q); print(f"source is {bits}-bit: rounding capture to {bits}-bit matches {m.mean()*100:.4f}% ({(~m).sum()} samples differ)")
# does undoing the measured gain make it exact?
for bits in (16, 24):
    q = 2.0 ** (bits - 1)
    if np.all(np.round(b * q) == b * q):
        m = np.round(a / g * q) == np.round(b * q); print(f"  after dividing out the gain: {m.mean()*100:.4f}% ({(~m).sum()} differ)")
