#!/usr/bin/env python3
"""Music-only bench check on the engine's debug recordings (RendererDebugRecord: <prefix>.in.f32 =
what A read from loopback ch 1-2, <prefix>.out.f32 = what B played; stereo float32).

  silence <prefix>            -> nonzero frames in .in/.out (Music paused, another app playing: 0 = pass)
  same <prefixA> <prefixB>    -> the same local track played from 0 in both runs (B with another app
                                 playing): align on the first nonzero frame, count differing samples
"""
import sys, numpy as np

def load(p):
    a = np.fromfile(p, dtype='<f4')
    return a[: len(a) // 2 * 2].reshape(-1, 2)

def first_nz(a):
    nz = np.flatnonzero(np.any(a != 0, axis=1))
    return int(nz[0]) if len(nz) else None

if sys.argv[1] == 'silence':
    for ext in ('in', 'out'):
        a = load(f'{sys.argv[2]}.{ext}.f32')
        nz = np.any(a != 0, axis=1)
        print(f'{ext}: {len(a)} frames, nonzero {int(nz.sum())}, peak {float(np.abs(a).max()) if len(a) else 0:.6g}')
elif sys.argv[1] == 'same':
    # Music fades in after a play or seek, so the first nonzero frames differ between runs. Anchor on
    # a chunk well inside run A (5 s after its first nonzero frame), find it exactly in run B, then
    # compare everything from there to the end of the shorter overlap.
    a, b = load(f'{sys.argv[2]}.in.f32'), load(f'{sys.argv[3]}.in.f32')
    ia = first_nz(a) + 5 * 44100
    # exact search: positions where B's frame equals A's anchor frame, then the 4096-frame chunk
    cands = np.flatnonzero((b[:, 0] == a[ia, 0]) & (b[:, 1] == a[ia, 1]))
    ib = next((int(k) for k in cands if np.array_equal(b[k:k + 4096], a[ia:ia + 4096])), None)
    if ib is None:
        print(f'anchor chunk not found bit-exact in B ({len(cands)} single-frame matches)'); sys.exit(1)
    n = min(len(a) - ia, len(b) - ib)
    x, y = a[ia:ia + n], b[ib:ib + n]
    diff = np.flatnonzero(np.any(x != y, axis=1))
    print(f'anchor A {ia} = B {ib}; compared {n} frames ({n/44100:.1f} s at 44.1k); differing frames {len(diff)}'
          + (f'; first at +{diff[0]} (A {x[diff[0]]} B {y[diff[0]]})' if len(diff) else '; bit-exact'))
