#!/usr/bin/env python3
# vsegcheck.py <prefix>: pass-through check for a run of the engine (LosslessSwitcher's
# VirtualDeviceEngine debug recording, vrender's format). Unlike vcheck.py it doesn't assume one
# constant delay: at each switch the ring is flushed, and gate/latch holds insert zeros in the
# output. So per rate segment (<prefix>.segments.txt for out, .in.segments.txt for in, one entry
# per setup/switch in both), the output is split into runs of signal (gaps >= 20 ms of exact zeros),
# each run is located in the input segment and compared sample for sample.
import sys, numpy as np
pre = sys.argv[1]
inp = np.fromfile(pre + ".in.f32", dtype=np.float32).reshape(-1, 2)
out = np.fromfile(pre + ".out.f32", dtype=np.float32).reshape(-1, 2)
so = [tuple(map(float, l.split())) for l in open(pre + ".segments.txt") if l.strip()]
si = [tuple(map(float, l.split())) for l in open(pre + ".in.segments.txt") if l.strip()]
print(f"in {len(inp)} frames, out {len(out)} frames; segments out {len(so)}, in {len(si)}")
bo = [int(s[0]) for s in so] + [len(out)]
bi = [int(s[0]) for s in si] + [len(inp)]
total = bad_total = 0
for k in range(min(len(so), len(si))):
    rate = int(so[k][1])
    o = out[bo[k]:bo[k + 1]]
    # the input's segment starts at the virtual device's rate change; frames before the next
    # segment's start still belong to it
    i = inp[bi[k]:bi[k + 1]]
    nz = np.flatnonzero(np.abs(o).max(axis=1) > 0)
    print(f"segment {k + 1}: {rate} Hz, out {len(o)} frames ({len(o) / rate:.2f} s), in {len(i)} frames")
    if not len(nz):
        continue
    brk = np.flatnonzero(np.diff(nz) > rate // 50)
    runs = [(nz[0] if j == 0 else nz[brk[j - 1] + 1], nz[brk[j]] if j < len(brk) else nz[-1]) for j in range(len(brk) + 1)]
    pos = 0
    for a, b in runs:
        run = o[a:b + 1]
        w = run[:64]
        cand = np.flatnonzero((i[pos:, 0] == w[0, 0]) & (i[pos:, 1] == w[0, 1])) + pos
        at = next((c for c in cand if c + len(w) <= len(i) and np.array_equal(i[c:c + len(w)], w)), None)
        if at is None:
            print(f"  run out {a}-{b} ({(b - a + 1) / rate:.2f} s): NOT FOUND in the input segment")
            continue
        n = min(len(run), len(i) - at)
        d = np.flatnonzero(np.any(run[:n] != i[at:at + n], axis=1))
        total += n; bad_total += len(d) + (len(run) - n)
        print(f"  run out {a}-{b} ({(b - a + 1) / rate:.2f} s) = in {at}-{at + n - 1}: "
              + ("bit-exact" if not len(d) and n == len(run) else f"{len(d)} frames differ (first at run frame {d[0] if len(d) else '-'}), {len(run) - n} past the input"))
        pos = at + n
print(f"total: {total} frames compared, {bad_total} differ" + (" -> bit-exact pass-through" if total and not bad_total else ""))
