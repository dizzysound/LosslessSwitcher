# Reports level of the 1 kHz reference and the 30 kHz probe in a recording.
# If the probe is ~equal to the reference, no conversion through <=48 kHz occurred.
import sys, numpy as np, subprocess
def load(path):
    raw = subprocess.run(["sox", path, "-t", "f32", "-", "remix", "1"], capture_output=True).stdout
    rate = int(subprocess.run(["soxi", "-r", path], capture_output=True, text=True).stdout)
    return np.frombuffer(raw, dtype=np.float32), rate
for path in sys.argv[1:]:
    x, sr = load(path)
    x = x[int(0.5*sr):]  # skip start-up
    if np.max(np.abs(x)) < 1e-4: print(f"{path}: SILENT"); continue
    spec = np.abs(np.fft.rfft(x * np.hanning(len(x))))
    f = np.fft.rfftfreq(len(x), 1/sr)
    def db(hz): return 20*np.log10(spec[(f > hz-50) & (f < hz+50)].max() + 1e-12)
    ref, probe = db(1000), (db(30000) if sr > 60000 else float('-inf'))
    print(f"{path}: rate={sr} 1kHz={ref:.1f}dB 30kHz={probe:.1f}dB  delta={probe-ref:.1f}dB  -> "
          + ("30 kHz PRESERVED" if probe-ref > -20 else "30 kHz LOST (resampled via <=48k)"))
