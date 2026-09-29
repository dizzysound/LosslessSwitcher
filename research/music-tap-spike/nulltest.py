# nulltest.py <capture.f32> <channels> <source audio file>
# Aligns the first two channels of a tap capture with Apple's decode of the source file and
# compares them sample by sample.
import subprocess, sys, tempfile, os, numpy as np
cap_path, ch, src = sys.argv[1], int(sys.argv[2]), sys.argv[3]
rate = float(sys.argv[4]) if len(sys.argv) > 4 else 44100.0
cap = np.fromfile(cap_path, dtype=np.float32).reshape(-1, ch)[:, :2].astype(np.float64)
tmp = tempfile.mktemp(suffix=".wav")
subprocess.run(["afconvert", "-f", "WAVE", "-d", "LEF32", src, tmp], check=True)
raw = open(tmp, "rb").read(); os.remove(tmp)
i = raw.find(b"data"); n = int.from_bytes(raw[i+4:i+8], "little")
srcd = np.frombuffer(raw[i+8:i+8+n], dtype=np.float32).reshape(-1, 2).astype(np.float64)
first = np.argmax(np.abs(cap[:, 0]) > 1e-6)
# find where a 0.5 s piece of the capture sits in the first 60 s of the source (FFT cross-correlation)
seg = cap[first + int(rate):first + int(rate * 1.5), 0]
ref = srcd[:int(rate * 60), 0]
nfft = 1 << int(np.ceil(np.log2(len(ref) + len(seg))))
cc = np.fft.irfft(np.fft.rfft(ref, nfft) * np.conj(np.fft.rfft(seg, nfft)), nfft)[:len(ref) - len(seg)]
pos = int(np.argmax(cc))  # source index matching cap[first + rate]
off = first + int(rate) - pos  # capture index of source frame 0 (may be negative)
cs, ss = (off, 0) if off >= 0 else (0, -off)
L = min(len(cap) - cs, len(srcd) - ss)
a, b = cap[cs:cs + L], srcd[ss:ss + L]
d = a - b
print(f"capture {len(cap)} frames, source {len(srcd)} frames, offset {off}, compared {L} frames ({L/rate:.1f} s)")
print(f"identical samples: {np.mean(d == 0) * 100:.4f}%  max |diff| = {np.max(np.abs(d)):.3e} = {np.max(np.abs(d)) * 2**23:.2f} LSB@24-bit = {np.max(np.abs(d)) * 2**15:.4f} LSB@16-bit")
g = np.dot(a[:, 0], b[:, 0]) / np.dot(b[:, 0], b[:, 0]); print(f"gain {g:.8f}")
for bits in (16, 24):
    q = 2.0 ** (bits - 1)
    ra, rb = np.round(a * q), np.round(b * q)
    src_exact = np.all(rb == b * q)
    print(f"requantized to {bits}-bit: {np.mean(ra == rb) * 100:.4f}% identical, max |diff| {np.max(np.abs(ra - rb)):.0f} LSB (source is exactly {bits}-bit: {src_exact})")
