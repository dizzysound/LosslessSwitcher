# outcheck.py <run prefix> <rate>=<source file> ...: follows what the renderer actually output.
# Splits each pipeline segment's output (<prefix>.out.f32) into runs of signal (gaps < 20 ms of exact
# zeros are kept inside a run and reported as dropouts), locates each run's start in Apple's decode
# of the source played at that rate, and checks the run matches the source contiguously from there
# (exact after rounding to 16 bits, or within 1 LSB at 24 bits). Wall-clock times come from the
# per-cycle host times in <prefix>.cycles.txt, so silences between runs (including teardowns, where
# no frames are recorded) are measured in real time.
import sys, subprocess, tempfile, os, numpy as np
pre = sys.argv[1]
srcs = [(float(a.split("=", 1)[0]), a.split("=", 1)[1]) for a in sys.argv[2:]]   # several per rate allowed
out = np.fromfile(pre + ".out.f32", dtype=np.float32).reshape(-1, 2).astype(np.float64)
segs = [tuple(map(float, l.split())) for l in open(pre + ".segments.txt") if l.strip()]
cyc = np.array([list(map(float, l.split())) for l in open(pre + ".cycles.txt") if l.strip()])
cstart = np.concatenate([[0], np.cumsum(cyc[:, 1])[:-1]])            # first frame of each cycle
host = cyc[:, 3] * 125 / 3 / 1e9; host -= host[0]                    # seconds (Apple Silicon timebase)
def wall(k):  # wall-clock time of output frame k
    i = np.searchsorted(cstart, k, side="right") - 1; rate = segs[np.searchsorted([s[0] for s in segs], k, side="right") - 1][1]
    return host[i] + (k - cstart[i]) / rate
cache = {}
def decode(path):
    if path not in cache:
        tmp = tempfile.mktemp(suffix=".wav"); subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32", path, tmp], check=True)
        raw = open(tmp, "rb").read(); os.remove(tmp); i = raw.find(b"data"); n = int.from_bytes(raw[i+4:i+8], "little")
        cache[path] = np.frombuffer(raw[i+8:i+8+n], dtype=np.float32).reshape(-1, 2).astype(np.float64)
    return cache[path]
bounds = [int(s[0]) for s in segs] + [len(out)]
prev_end = None
for k, (st, rate) in enumerate(segs):
    R = int(rate); o = out[bounds[k]:bounds[k + 1]]
    nz = np.flatnonzero(np.abs(o).max(axis=1) > 0)
    print(f"segment {k+1}: {R} Hz, frames {bounds[k]}-{bounds[k+1]} ({len(o)/R:.2f} s), wall {wall(bounds[k]):.3f}-{wall(bounds[k+1]-1):.3f} s")
    if not len(nz): continue
    brk = np.flatnonzero(np.diff(nz) > R // 50)                      # zero gaps >= 20 ms split runs
    runs = [(nz[0] if i == 0 else nz[brk[i - 1] + 1], nz[brk[i]] if i < len(brk) else nz[-1]) for i in range(len(brk) + 1)]
    cands = [decode(p) for r, p in srcs if r == rate]
    for a, b in runs:
        ga, gb = bounds[k] + a, bounds[k] + b
        line = f"  run: wall {wall(ga):8.3f}-{wall(gb):8.3f} s ({(b - a + 1)/R:6.2f} s)"
        if prev_end is not None: line += f", silence before it {wall(ga) - prev_end:.3f} s"
        prev_end = wall(gb)
        q = 2.0 ** 23; m0 = a + R // 4; w = o[m0:m0 + R // 20, 0]          # align 250 ms into the run
        found = None
        for s in (cands if b - a > R // 2 else []):
            cand = np.flatnonzero(np.abs(s[:, 0] - w[0]) * q <= 2)
            def err(p): y = s[p:p + len(w), 0]; return np.abs(w - y).max() * q if len(y) == len(w) else 99
            p = min(cand, key=err, default=None)
            if p is not None and err(p) <= 2: found = (s, p); break
        if b - a > R // 2 and cands:
            if found is None: line += "  [not found in sources]"
            else:
                s, p = found; src_i = next(i for i, c in enumerate(cands) if c is s)
                p0 = p - (m0 - a)                                         # source frame at run start
                lo = max(0, -p0); n = min(b - a + 1, len(s) - p0)
                x = o[a + lo:a + n]; y = s[p0 + lo:p0 + n]
                d = np.abs(x - y).max(axis=1) * q
                bad = np.flatnonzero(d > 1)
                head = bad[bad < R // 4]; lead = (head[-1] + 1) / R if len(head) else 0.0   # start transition
                tail = bad[bad >= R // 4]
                dz = int(((x[:, 0] == 0) & (np.abs(y[:, 0]) > 1e-4)).sum())
                exact16 = (np.round(x * 32768) == np.round(y * 32768)).all(axis=1)[int(lead * R):].mean() * 100
                snz = np.flatnonzero(np.abs(s[:, 0]) > 0)[0] / R
                line += (f"  src#{src_i} {(p0+lo)/R:7.3f}-{(p0+n)/R:7.3f} s (source's first signal at {snz:.3f} s);"
                         f" start transition {lead*1000:.0f} ms; after it: frames > 1 LSB@24 {len(tail)}, dropouts {dz}, 16-bit exact {exact16:.4f}%")
                if len(tail): line += f" (bad from +{tail[0]/R:.3f} s to +{tail[-1]/R:.3f} s)"
        print(line)
