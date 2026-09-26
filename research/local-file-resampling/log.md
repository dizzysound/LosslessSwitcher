# Does Music still double-resample local files after a device rate change? (macOS 26.6.2)

Question from upstream discussion #74 (2023): for local files, Music converts to the device rate
captured at Music launch, then CoreAudio converts to the device's current rate.

## Rig (2026-09-26)
- `tone96k.wav` / `.m4a` (ALAC 24/96): 1 kHz + 30 kHz sines, both channels. 30 kHz survives only
  if nothing in the chain runs at <=48 kHz.
- Output device: Rogue Amoeba "Loopback Audio"; record its input with sox at 96 kHz.
- `analyze.py` reports 30 kHz level relative to 1 kHz. Source file = -6 dB.
- Validated: sox -> Loopback -> sox passthrough = -6.0 dB (PRESERVED);
  offline 96k->44.1k->96k copy = -155.5 dB (LOST).
- Gotcha: `sox -n -r 96000 ...` sets the OUTPUT rate; synth ran at 48k and aliased 30k to 18k.
  Use `sox -r 96000 -n ...`.

## Results (2026-09-26, macOS 26.6.2 build 25G83, Music.app, Loopback Audio as output)
30 kHz probe relative to 1 kHz (source = -6.0 dB; converted through 44.1k = -155 dB):

| Trial | Music launched at | Track started at | Recorded at | 30 kHz | Null vs source |
|---|---|---|---|---|---|
| A  ALAC | 44.1k | 96k | 96k | -6.0 dB PRESERVED | residual -154 dB, max 1 LSB @24-bit, gain 1.000000 |
| B  ALAC (control) | 96k | 96k | 96k | -6.0 dB PRESERVED | residual -154 dB, max 1 LSB |
| C  ALAC | 44.1k | 44.1k, switched to 96k mid-track | 96k | -6.0 dB PRESERVED | - |
| D  WAV  | 44.1k | 44.1k, switched to 96k mid-track | 96k | -6.0 dB PRESERVED | - |

**Conclusion:** the launch-rate double-resampling from discussion #74 does not reproduce on
macOS 26.6.2. A (the bug scenario) is identical to the B control. C/D (LosslessSwitcher's real
sequence) also show no <=48k stage.

Side findings:
- The existing coreaudio log parser already sees local ALAC:
  `ACAppleLosslessDecoder.cpp:680 Input format: 2 ch, 96000 Hz, alac ... from 24-bit source`.
  WAV/AIFF do not go through that decoder, so they need another path.
- `tell application "Music" to get sample rate of current track` returns 96000 for local files.
- Adding a file whose name matches an existing track returns the EXISTING track's persistent ID
  (first WAV trial silently replayed the ALAC; rerun with a distinct name).

Limits: one virtual output device (Loopback), one machine, 96k-over-44.1k only. Not tested:
a hardware DAC, 88.2/176.4/192k, Music launched at 48k, gapless transitions between rates.

Test tracks removed from library afterwards; the copies Music made in Media.localized were moved
to Trash; default output restored to MT 48 @ 44.1k; Loopback restored to 48k.

## Live check on the owner's library (2026-09-26 15:52)
- Playing "How Do You Think I Feel" (Elvis), Apple Lossless 96k/24, `file track`, cloud status
  `uploaded`, on /Volumes/Extreme SSD. `harness/localtrack` (compiles Quality/LocalTrack.swift
  standalone) -> 96000 Hz / 24 bit, matching `afinfo`.
- The installed upstream LosslessSwitcher switched MT 48 to 96k by itself, via the
  ACAppleLosslessDecoder log line. So local ALAC already works upstream; the toggle adds
  WAV/AIFF/FLAC/AAC/MP3 and makes a local file's header win over stale log lines.
- A cloud-only copy (`shared track`, AAC, `uploaded`) is not on disk; LocalTrack returns nil and the
  log path (ACMP4AACBaseDecoder, not parsed) does not see it either. Not handled.
- `harness/localtrack harness/fmt/*` correct for WAV 16/44.1 and 24/192, AIFF 16, ALAC 16/44.1 and
  24/192, FLAC 24/192, AAC and MP3 (reported 16 bit).
- Gotcha: in zsh, `log` is a builtin; use `/usr/bin/log show`. A zsh `log show ... 2>/dev/null`
  silently returns nothing.
