# sr192.py <Ventura 192k file> <run prefix> ...: for every 192k pipeline segment of each run, checks
# Music's audio in the tap 0.5-2.5 s after the segment's first signal: 24-40 kHz energy (this
# recording: ~-58 dB clean, -20..-24 dB in the corrupted segments) and whether 20 ms of it is found
# sample-exact in the source. Prints one line per segment and a tally per run.
import sys, subprocess, tempfile, os, numpy as np
src = sys.argv[1]; R = 192000; q = 2.0 ** 23
tmp = tempfile.mktemp(suffix=".wav"); subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32", src, tmp], check=True)
raw = open(tmp, "rb").read(); os.remove(tmp); i = raw.find(b"data"); n = int.from_bytes(raw[i+4:i+8], "little")
s = np.frombuffer(raw[i+8:i+8+n], dtype=np.float32).reshape(-1, 2)[:, 0].astype(np.float64)
for pre in sys.argv[2:]:
    tap = np.fromfile(pre + ".tap.f32", dtype=np.float32).reshape(-1, 2)[:, 0].astype(np.float64)
    segs = [tuple(map(float, l.split())) for l in open(pre + ".segments.txt") if l.strip()]
    b = [int(x[0]) for x in segs] + [len(tap)]; bad = tot = 0
    for k, (st, rate) in enumerate(segs):
        if rate != R: continue
        t = tap[b[k]:b[k + 1]]; nz = np.flatnonzero(np.abs(t) > 0)
        if len(nz) == 0 or nz[0] + 3 * R > len(t): print(f"{pre} seg {k+1}: too short"); continue
        x = t[nz[0] + R // 2:nz[0] + R // 2 + 2 * R]
        P = np.abs(np.fft.rfft(x * np.hanning(len(x)))) ** 2; f = np.fft.rfftfreq(len(x), 1 / R)
        hf = 10 * np.log10(P[(f >= 24.1e3) & (f < 40e3)].sum() / P.sum())
        w = x[R:R + R // 50]; cand = np.flatnonzero(np.abs(s - w[0]) * q <= 2)
        found = any(np.abs(s[p:p + len(w)] - w).max() * q <= 2 for p in cand if p + len(w) <= len(s))
        corrupt = hf > -40; tot += 1; bad += corrupt
        print(f"{pre} seg {k+1}: 24-40 kHz {hf:6.1f} dB, sample-exact in source: {found} -> {'CORRUPT' if corrupt else 'ok'}")
    print(f"== {pre}: {bad}/{tot} corrupted")
