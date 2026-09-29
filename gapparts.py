# gapparts.py <run prefix>: per --auto switch routine, where the time goes: request -> device ready,
# ready -> unmute (hold, build, pause/rewind, quiet wait), Music's play -> its first sound in the tap,
# then the delay line. Needs the renderer log, <prefix>.tap.f32 and <prefix>.segments.txt.
import sys, re, numpy as np
pre = sys.argv[1]; L = open(pre + ".log").read().split("\n")
tap = np.fromfile(pre + ".tap.f32", dtype=np.float32).reshape(-1, 2)
segs = [tuple(map(float, l.split())) for l in open(pre + ".segments.txt") if l.strip()]
T = lambda l: float(l[1:l.index("]")])
cur = None
for l in L:
    m = re.search(r"switch (\d+): .*rate (\d+)", l)
    if m: cur = {"n": int(m.group(1)), "rate": int(m.group(2)), "req": T(l)}
    if cur is None: continue
    if "device ready" in l or "device NOT ready" in l: cur["ready"] = T(l)
    m = re.search(r"unmuting, play$", l) and re.search(r"at frame (\d+)", l)
    if m: cur["unmute"] = T(l); cur["uf"] = int(m.group(1))
    if re.search(rf"switch {cur['n']} done", l):
        uf = cur.get("uf"); R = cur["rate"]
        nz = np.flatnonzero(np.abs(tap[uf:uf + 2 * R, 0]) > 0) if uf else []
        lat = nz[0] / R if len(nz) else float("nan")
        r = cur.get("ready", cur["req"])
        print(f"switch {cur['n']:2d} -> {R/1000:5.1f}k: request->ready {r - cur['req']:5.2f} s, ready->unmute {cur.get('unmute', r) - r:4.2f} s, "
              f"play->first sound {lat:4.2f} s, + delay 0.20 -> request->audible {cur.get('unmute', r) - cur['req'] + lat + 0.2:4.2f} s")
        cur = None
