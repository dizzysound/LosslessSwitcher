# repro192.py <name> <rounds> <Ventura file>: for each TapCapture file of repro192.sh, ch 1-2 vs the
# 192k source: exact match (24-bit, after locating the capture in the source) and the energy in
# 24-40 kHz relative to the total (good 192k segments of this track: ~-58 dB; corrupted: -20..-24 dB).
import sys, subprocess, tempfile, os, re, numpy as np
name, rounds, src = sys.argv[1], int(sys.argv[2]), sys.argv[3]; R = 192000
tmp = tempfile.mktemp(suffix=".wav"); subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32", src, tmp], check=True)
raw = open(tmp, "rb").read(); os.remove(tmp); i = raw.find(b"data"); n = int.from_bytes(raw[i+4:i+8], "little")
s = np.frombuffer(raw[i+8:i+8+n], dtype=np.float32).reshape(-1, 2).astype(np.float64)
for k in range(1, rounds + 1):
    log = open(f"runs/{name}.{k}.log").read(); m = re.search(r"tap format: ([0-9.]+) Hz, (\d+) ch", log)
    rate, ch = float(m.group(1)), int(m.group(2))
    t = np.fromfile(f"runs/{name}.{k}.f32", dtype=np.float32).reshape(-1, ch)[:, :2].astype(np.float64)
    nz = np.flatnonzero(np.abs(t[:, 0]) > 0)
    if rate != R or len(nz) < R: print(f"round {k}: tap {rate:.0f} Hz, {len(nz)/max(rate,1):.2f} s of signal - skipped"); continue
    x = t[nz[0] + R // 2:nz[0] + R // 2 + 2 * R, 0]
    P = np.abs(np.fft.rfft(x * np.hanning(len(x)))) ** 2; f = np.fft.rfftfreq(len(x), 1 / R)
    hf = 10 * np.log10(P[(f >= 24.1e3) & (f < 40e3)].sum() / P.sum())
    w = x[:R // 50]; q = 2.0 ** 23
    cand = np.flatnonzero(np.abs(s[:12 * R, 0] - w[0]) * q <= 2)
    def err(p): y = s[p:p + len(w), 0]; return np.abs(w - y).max() * q if len(y) == len(w) else 1e9
    p = min(cand, key=err, default=None)
    if p is not None and err(p) <= 2:
        y = s[p:p + len(x), 0]; exact = (np.abs(x - y) * q <= 1).mean() * 100; where = f"at source {p/R:.2f} s, 24-bit (<=1 LSB) {exact:.3f}%"
    else: where = "NOT found in source (sample-exact)"
    print(f"round {k}: 24-40 kHz {hf:6.1f} dB; {where} -> {'CORRUPT' if hf > -40 else 'ok'}")
