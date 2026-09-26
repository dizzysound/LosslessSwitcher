# Align recording to source and report residual after subtraction (bit-perfect => -inf / ~-144 dB).
import sys, numpy as np, subprocess
def load(p): return np.frombuffer(subprocess.run(["sox", p, "-t", "f64", "-", "remix", "1"], capture_output=True).stdout, dtype=np.float64)
src = load("tone96k.wav")
for p in sys.argv[1:]:
    rec = load(p); rec = rec[np.nonzero(np.abs(rec) > 1e-6)[0][0]:]  # from first non-silent sample
    n = min(len(rec), len(src)) - 96000; seg = rec[48000:48000+n//2]
    # search offset of seg inside src
    best = min(range(0, len(src)-len(seg), 1) if False else [], default=None)
    c = np.correlate(src[:len(seg)+96000], seg[:4096], mode="valid"); off = int(np.argmax(c))
    s = src[off:off+len(seg)]; gain = np.dot(s, seg)/np.dot(s, s); r = seg - s*gain
    print(f"{p}: gain={gain:.6f} ({20*np.log10(gain):+.3f} dB) residual={20*np.log10(np.sqrt(np.mean(r**2))/np.sqrt(np.mean(s**2))+1e-300):.1f} dB rel. signal, max|diff|*2^23={np.max(np.abs(seg-s))*2**23:.2f}")
