#!/usr/bin/env python3
# vcheck.py <prefix> [--settle <s>]: checks a vrender run.
# 1. Pass-through: what B played (<prefix>.out.f32) must be what A read from the virtual device's
#    loopback (<prefix>.in.f32), sample for sample, delayed by the ring (FIFO: no drops, no repeats).
# 2. Clock: from <prefix>.clock.csv, the phase error between the virtual device's and the DAC's time
#    lines once locked (after --settle seconds, default 20), the ring fill, the scalars, and the
#    free-running drift (phase slope) when the run was --nolock.
import sys, numpy as np
pre = sys.argv[1]
settle = float(sys.argv[sys.argv.index("--settle") + 1]) if "--settle" in sys.argv else 20.0
inp = np.fromfile(pre + ".in.f32", dtype=np.float32).reshape(-1, 2)
out = np.fromfile(pre + ".out.f32", dtype=np.float32).reshape(-1, 2)
print(f"in {len(inp)} frames, out {len(out)} frames")
nzi = np.flatnonzero(np.abs(inp).max(axis=1) > 0)
nzo = np.flatnonzero(np.abs(out).max(axis=1) > 0)
if len(nzi) == 0 or len(nzo) == 0:
    print(f"no signal (in nonzero {len(nzi)}, out nonzero {len(nzo)})")
else:
    # align on the first 256 nonzero frames of the input
    i1 = nzi[0]; w = inp[i1:i1 + 256]
    cand = np.flatnonzero((out[:, 0] == w[0, 0]) & (out[:, 1] == w[0, 1]))
    off = next((c - i1 for c in cand if c + 256 <= len(out) and np.array_equal(out[c:c + 256], w)), None)
    if off is None:
        print("could not align out to in")
    else:
        n = min(len(inp), len(out) - off)
        a, b = inp[:n], out[off:off + n]
        bad = np.flatnonzero(np.any(a != b, axis=1))
        print(f"out = in delayed by {off} frames; compared {n} frames ({n - i1} from the first signal): "
              f"{len(bad)} differ" + (f", first at in frame {bad[0]}" if len(bad) else " -> bit-exact pass-through"))
        print(f"signal: in frames {nzi[0]}-{nzi[-1]}, peak {np.abs(inp).max():.4f}")
import csv
rows = list(csv.DictReader(open(pre + ".clock.csv")))
t = np.array([float(r["t"]) for r in rows]); err = np.array([float(r["err"]) for r in rows])
fill = np.array([float(r["fill"]) for r in rows]); ph = np.array([float(r["phase"]) for r in rows])
dac = np.array([float(r["dacScalarHAL"]) for r in rows]); lsh = np.array([float(r["lsScalarHAL"]) for r in rows])
lss = np.array([float(r["lsScalarSet"]) for r in rows])
under = int(rows[-1]["underruns"]); over = int(rows[-1]["overruns"])
print(f"clock: {len(rows)} samples over {t[-1] - t[0]:.0f} s; underruns {under} frames, overruns {over} frames")
m = t >= t[0] + settle
if m.sum() > 2:
    print(f"after {settle:.0f} s: phase err mean {err[m].mean():+.2f} rms {np.sqrt((err[m] ** 2).mean()):.2f} max|.| {np.abs(err[m]).max():.2f} frames; "
          f"fill {fill[m].min():.0f}-{fill[m].max():.0f}")
    print(f"  DAC scalar (HAL) {dac[m].mean():.9f} (sd {dac[m].std() * 1e6:.2f} ppm); LS scalar set {lss[m].mean():.9f} "
          f"(sd {lss[m].std() * 1e6:.2f} ppm); LS scalar (HAL) {lsh[m].mean():.9f}")
    if np.all(lss == lss[0]):   # free-running: the drift is the phase slope
        k = np.polyfit(t[m], ph[m], 1)[0]
        rate = None
        try:
            rate = float(open(pre + ".segments.txt").read().split()[1])
        except Exception:
            pass
        print(f"  free-running phase slope {k:+.3f} frames/s" + (f" = {k / rate * 1e6:+.2f} ppm" if rate else ""))
