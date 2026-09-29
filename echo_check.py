# echo_check.py <run prefix> <mic.wav>: estimates the impulse response from the Music tap (mono,
# resampled to 48k) to a mic recording, and reports its biggest arrivals. If Music's own output
# leaks while the renderer plays, a second arrival shows up ~(renderer lag) after the first.
import sys, numpy as np
from scipy.io import wavfile
from scipy.signal import resample_poly
pre, micf = sys.argv[1], sys.argv[2]
tap = np.fromfile(pre + ".tap.f32", dtype=np.float32).reshape(-1, 2).mean(axis=1).astype(np.float64)
x = resample_poly(tap, 1, 2)  # 96k -> 48k
sr, m = wavfile.read(micf); m = m.astype(np.float64); m /= np.abs(m).max()
# coarse alignment: where does the mic recording sit in the tap timeline?
N = 1 << 21
cc = np.fft.irfft(np.fft.rfft(x, N) * np.conj(np.fft.rfft(m, N)), N)
off = int(np.argmax(cc[:len(x)]))
seg = x[off - 2400: off - 2400 + len(m)]  # reference starting 50 ms earlier than the mic
L = min(len(seg), len(m))
X, M = np.fft.rfft(seg[:L], N), np.fft.rfft(m[:L], N)
h = np.fft.irfft(M * np.conj(X) / (np.abs(X) ** 2 + 1e-3 * np.mean(np.abs(X) ** 2)), N)[:4800]
h /= np.abs(h).max()
pk = np.argsort(-np.abs(h))
peaks = []
for p in pk:
    if all(abs(p - q) > 24 for q in peaks): peaks.append(p)
    if len(peaks) == 5: break
p0 = int(np.argmax(np.abs(h)))
print(f"{pre.split('/')[-1]}: offset {off}; main arrival at {p0/48:.2f} ms; strongest arrivals (ms after main, level):",
      ", ".join(f"{(p - p0)/48:+.2f} ms {abs(h[p]):.2f}" for p in sorted(peaks)))
for d in (1070 / 96, ):  # expected renderer lag in ms
    k = p0 + int(round(d * 48)); w = np.abs(h[k - 5:k + 6]).max()
    print(f"  level near +{d:.2f} ms: {w:.3f}; median |h| elsewhere {np.median(np.abs(h)):.4f}")
