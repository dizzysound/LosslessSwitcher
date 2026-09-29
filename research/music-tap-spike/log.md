# Music process-tap spike (2026-09-27)

Question: can Music's audio (local files and Apple Music streams) be captured bit-exactly with a
Core Audio process tap (macOS 14.4+), as the input to a separate low-level renderer?

## Setup
- tapcapture.swift -> TapCapture.app (make_app.sh). An app bundle is needed: a CLI launched from
  Claude Code is attributed to com.anthropic.claude-code and tccd refuses kTCCServiceAudioCapture.
  TapCapture.app got its own "System Audio Recording" grant (TCC auth_value 2).
- Tap: CATapDescription(processes: [Music], deviceUID: MT 48, stream: 0), unmuted, private;
  private aggregate [MT 48 as main/clock + tap]; IOProc copies the tap buffer to raw float32.
  Tap format = the device stream's: 16 ch float32 interleaved at the device rate; Music on ch 1-2.
- nulltest.py / steady.py: Apple's decode of the source (afconvert LEF32) vs the capture, aligned
  by cross-correlation (steady.py tries two alignments and keeps the smaller residual), first 50 ms
  of the track skipped (start-of-playback transition, see below).
- Music volume 100, Sound Check / Sound Enhancer / EQ off, Atmos Off; LosslessSwitcher quit.

## Results (MT 48)
| Test | Source | Gain | Max error | Rounded to source depth |
|---|---|---|---|---|
| A | Backwoods Song, ALAC 16/44.1 | 1 - 3.29e-8 | 0.75 LSB@24 | 16-bit: 100.0000% identical |
| B | Skyfall, ALAC 24/96 | 1 - 3.24e-8 | 1.0 LSB@24 | 24-bit: 99.9169% (2473 samples off by 1) |
| D | Apple Music stream, Arcade Fire "Age of Anxiety I" (ALAC 24/96) | - | - | captured: 9.8 s non-silent, peak 0.30 |

- Music at "100%" applies a gain of 1 - ~3.3e-8 before the tap (same in A and B). 16-bit sources
  are recoverable exactly by rounding; 24-bit sources are not (0.08% of samples off by 1 LSB, about
  -144 dBFS). Dividing out the measured gain still leaves 0.04% off. Consistent with the earlier
  Music -> Loopback null test (max 1 LSB@24).
- Can't separate Music's contribution from the tap's; both are upstream of any renderer.
- First ~32 ms after starting a track contained non-silent samples where the source is silent
  (up to 95 LSB@24): a playback-start transition.
- DRM streams are NOT silenced by a process tap.
- The aggregate took ~1.5 s to start at 44.1k and ~8 s at 96k right after a rate change (the MT 48's
  restart behavior); a renderer must tolerate that.

## Not tested
Driving the DAC from the tap (renderer), hog mode / non-mixable format on a device inside an
aggregate, clock drift, mid-stream rate changes, a stream against a reference (impossible: DRM).

## Conclusion
A tap-based renderer can't be bit-perfect for 24-bit material, because Music's own output isn't:
the samples are altered (inaudibly) before capture. For bit-perfect local playback a renderer must
decode the files itself (BitPerfect's approach); the tap only helps streams, where it gives the
same near-transparent result Music already sends to the DAC.

---

# Renderer step (branch `renderer`, 2026-09-27)

Start state: output MT 48 @ 96 kHz, Music paused at volume 100, LosslessSwitcher running (quit for
the tests). macOS 26.6.2.

## Device-side experiments (devtest.swift, CLI, no tap, so no capture permission needed)
devprobe.swift dumps a device's streams/formats. devtest.swift plays -40 dBFS 24-bit-exact noise on
ch 1-2 of the MT 48 through a private aggregate [MT 48 as main] (or directly with --direct), with
optional hog mode / non-mixable physical format / mid-run rate switch, recording the device inputs.

- MT 48: one output stream, 16 ch, physical int32 (flags 12 mixable; flags 76 = signed|packed|
  non-mixable also offered at every rate); virtual float32 16 ch. Input stream 8 ch (a 16 ch format is
  also offered). Buffer 512 frames, output latency 60 + safety offset 26 frames.
- **No loopback at the USB inputs**: with 8 or 16 input channels, none carries the played signal
  (ch 1 is a live input at ~0.002 peak, the rest ~1e-6 or 0). Verifying "what reaches the device"
  in hardware needs a loopback routed in the MT 48's own mixer (not tried; it's device config).
- **Hog mode works with the device inside an aggregate**: setting kAudioDevicePropertyHogMode on the
  MT 48 to our pid (status 0), then creating the private aggregate over it from the same process,
  runs normally. The aggregate itself reports hog owner 0.
- **Non-mixable format works inside an aggregate**: setting the MT 48 output stream's physical
  format to flags 76 makes the aggregate's output stream report physical AND virtual 16 ch int32
  flags 76, and the IOProc gets int32 buffers (the HAL does no float conversion/mixing). It was
  accepted with or without hog mode.
- **Rate change mid-run**: setting the MT 48's nominal rate while the aggregate runs (96k -> 44.1k
  mixable; 44.1k -> 96k with hog + non-mixable): IO stalls ~1.0 s, then the aggregate resumes at the
  new rate on its own, with the same IOProc; the non-mixable format and hog mode survive the switch.
- First IO cycle arrives 0.07-1.5 s after AudioDeviceStart (varies run to run).
- Trap: restoring a saved physical-format struct also restores its sample rate. Restore by clearing
  the non-mixable flag on the *current* format.

## Renderer with the Music tap (renderer.swift -> Renderer.app, trial.sh, analyze.py)
Private aggregate [MT 48 main/clock + Music tap (muted) + optional monitor tap], no drift
compensation; IOProc copies Music tap ch 1-2 to output ch 1-2 in the same cycle, zeros ch 3-16.
Monitor tap = CATapDescription(excludingProcesses: [Music], MT 48, stream 0) records what the HAL
mixes for the device from everyone but Music (i.e. our output). Test track Skyfall ALAC 24/96, MT 48
at 96k. Each rebuild of the ad-hoc app needs a new Allow click (4 builds so far).

- **m1, mixable, Music muted: output == tap, bit-exact.** Monitor vs Music tap: 100.0000% identical
  over 10.7 s at a lag of 1070 frames (11.1 ms at 96k; 2 x 512-frame buffers + 46). So in the
  mixable path, with no other process playing, the HAL delivers our float samples unchanged to the
  device's mix (float32 -> int32 is exact for <=24-bit data). Bit-exactness does NOT need hog or
  non-mixable mode, as long as nothing else plays to the device (system sounds would mix in).
- **Startup with a muting tap is rough**: first IO cycle 1.9-4.1 s after start, then ~8 short IO
  stalls with sample-time jumps over the next ~4 s while Music starts playing, and ~100 ms-spaced
  tap-format notifications (format unchanged). With `--mute unmuted` the first cycle came in 0.02 s
  with no stalls. Steady afterwards in all runs.
- **Mute can't be verified with a tap**: a monitor tap excluding no process (--monall) peaks at 1.33
  (Music + ours) whether Music is muted or not; taps see a process's audio before the mute. An
  acoustic check with the MacBook mic was inconclusive (mic didn't pick up the MT 48 clearly).
  **Confirmed by ear (Chris): the muted runs sounded clean** (one copy; an unmuted Music would add
  a second copy 11 ms later). MT 48 loopback to USB: unknown.
- **Hog mode + tap = no Music audio.** h2 (--hog before tapping): Music can't render to a hogged
  device and falls back to the MacBook Pro Speakers (Chris heard it there); the aggregate never
  ran (0 IO cycles in 15 s). Hog was released cleanly; Music went back to the MT 48 afterwards.
- **Non-mixable + tap = no tap.** h3 (--nonmix, no hog): both taps come back with an empty format
  (0 Hz, 0 ch), each after a ~1.1 s delay; the aggregate has no tap inputs. IO runs, but there's
  nothing to pass. (First build crashed on the missing inputs and left the MT 48 stuck non-mixable;
  `devprobe "MT 48" mixable` restores it. The renderer now guards and restores on SIGTERM/SIGINT.)
- **Taking the device over late** (h4, hog + non-mixable 3 s after the renderer runs): the Music tap
  follows into int32 flags 76 and keeps flowing ~5 s, then Music moves to the Mac speakers and the
  tap goes silent.
- Conclusion for exclusivity: a process tap needs Music to render into the same device's mix, so
  hog/non-mixable on that device and tapping Music on it are mutually exclusive. Exclusive access
  would need Music pointed at a *different* device (a virtual/null device) and tapped there, which
  puts the tap on another clock -> drift compensation (resampling) -> not bit-exact, unless that
  virtual device is slaved to the DAC's clock.

## Rate changes with the tap running (trial_rate.sh)
Renderer running (mixable), Skyfall 24/96 at 96k for ~10 s, then Music paused, the renderer sets
the MT 48 to 44.1k (via its command file, as LosslessSwitcher's pause-while-switching would), 3 s
later Backwoods Song 16/44.1 plays.
- The aggregate itself follows: device and aggregate report 44.1k ~0.15 s after the set, the Music
  tap's format follows to 44.1k, IO resumes ~1.0 s after the switch with the same IOProc.
- **But the Music tap is broken after the switch**: muted (rf1) and unmuted (rf_unmuted), no tap
  signal at all for the 44.1k track; mutedWhenTapped (rf_whenTapped): the track arrives in
  fragments, ~30 silent gaps of 0.1-0.75 s in 20 s, and the monitor tap (our output) is silent
  after the switch. Tap-format notifications keep firing (23-97 per run) though the format is
  unchanged. Played on its own afterwards, Backwoods plays normally on the MT 48.
- rf1 also stalled IO for 8.4 s when Skyfall started (the muted-tap startup problem, worse).
- MT 48 buffer size stays 512 whether Music plays or not, so the restarts aren't a buffer-size
  change.
- Next experiment: on a rate change, destroy the tap + aggregate and create fresh ones at the new
  rate (and compare muted vs mutedWhenTapped for startup stalls). A real add-on has to own the rate
  switch anyway: the tap delivers audio at the device rate, so the DAC must be set from the track's
  rate before Music renders, or Music resamples.

State restored after the tests: MT 48 default output @ 96 kHz, mixable, no hog; Music paused at
volume 100; LosslessSwitcher relaunched.

## Where things stand (checkpoint)
Answered: (1) passthrough in one aggregate on the DAC's clock works and is bit-exact at the HAL mix
(m1); (2) hog / non-mixable on the DAC can't coexist with tapping Music on that DAC; (3) output ==
tap verified in software up to the HAL mix (hardware verification needs an MT 48 loopback).
Open: (4) rate changes (tap breaks after a switch; rebuild-on-switch untested); startup stalls with
a muting tap. Music's mute confirmed by ear.

## Rebuild-on-switch (renderer.swift restructured; trial_rate.sh; segcheck.py)
Renderer now builds tap + aggregate as a "pipeline"; a `rate <hz>` command tears it down, sets
the MT 48's rate, waits for the device to report it (0.02-0.08 s), and builds a fresh one
(`--inplace` keeps the old set-under-a-running-aggregate behavior). A repeated `rate` command with
the same rate is a plain rebuild. REBUILD_AFTER=<s> in trial_rate.sh sends one <s> after the
second track starts. segcheck.py aligns each pipeline segment with its source (tracks start at 0).

| Run | Switch | Pipeline built right after the switch (before Music plays) | Rebuilt ~2 s after Music started the new track |
|---|---|---|---|
| rb1 | 44.1k -> 44.1k (no real change; LosslessSwitcher had left 44.1k) | worked | - |
| rb2 | 96k -> 44.1k | **silent** for 21 s | - |
| rb3 | 44.1k -> 96k | first IO after 6.1 s (MT 48 restart), then ~no IO | - |
| rb4 | 96k -> 44.1k | worked (signal from Music's start), 16-bit exact | 15.2 s, 0 dropouts, 16-bit 100.0000% exact, monitor == tap 100% |
| rb5 | 96k -> 44.1k | **silent** for 5 s | 15.7 s, 0 dropouts, 16-bit 100.0000% exact, monitor == tap 100% |
| rb6 | 44.1k -> 96k | worked, 24-bit 99.97% | 8.6 s, 0 dropouts, 24-bit 99.86% (Music's gain), monitor == tap 100% |

- **A tap created while Music is already playing the new track has been reliable (3/3).** A tap
  created before Music starts playing at the new rate is a coin toss (2/4 got audio).
- Rebuild cost: 0.1 s when the rate is unchanged; ~1.1 s for a real switch (the teardown/rate
  set is fast, the device's restart dominates); the MT 48 once took 6.1 s (rb3) going to 96k.
- The start-of-playback stall with a muted tap also hit pipeline 1 when Music started playing after
  the pipeline existed (rb4 ~7.7 s, rb5 ~10 s: segment 1 nearly empty). Same pattern: a muting tap
  that exists before Music starts is fragile.
- During a teardown Music is un-muted, so Music's own output reaches the DAC directly for that
  window, at the right rate, with the same samples: gaps are covered, not silent.
- 24-bit exactness per segment ranges 99.65-99.97% (Music's ~3.3e-8 gain; see the spike).

**Implied rate-follow design:** on a track change: (1) pause/let Music stop, (2) tear down,
(3) set the DAC to the track's rate, (4) let Music start the track (its direct output covers the
first moments), (5) when Music's process object reports kAudioProcessPropertyIsRunningOutput on the
DAC, build the tap + aggregate. Step 5 on a listener instead of a fixed 2 s delay is untested.

**On value vs Music + LosslessSwitcher (Chris asked):** the renderer's samples are the same ones
Music sends straight to the DAC (m1, and monitor == tap here), so it can't sound better. Its only
possible gains are in switching: owning the rate change and covering the device's restart. A
buffer can't get ahead of Music (the tap is real time), so it can't learn a track's rate early or
fill the device's restart with the track's start unless Music is held paused while the DAC settles
- which is what LosslessSwitcher's pause-while-switching fork already does.

## IsRunningOutput trigger -> playerInfo-gated trigger (renderer --follow; procwatch, playerinfo)
**What Music's process object does** (procwatch.swift, no renderer running, MT 48):
- Starting a track on an idle MT 48: IsRunningOutput and the device list flap on/off every ~100 ms
  for ~3.4 s before holding. This (not our tap) is the "startup stall" seen in earlier runs.
- Paused: output keeps running, stops ~2 s after idle; a rate change while paused makes Music
  restart its output anyway (running 1 for ~2 s with nothing playing).
- Rate change while playing: output drops and restarts within ~0.16 s.
- IsRunningOutput never fires a property listener (kAudioProcessPropertyDevices does); poll it.

**Trigger v1 (output restarted + steady 300 ms)**: fw2: fired on the startup (good; 96k segment
covered) and on the rate change, but that restart happened *while paused*; when Backwoods then
started, Music's output didn't restart, no trigger, tap silent 20.8 s. So the failure pattern in
rb2/rb5/fw2 is "tap built while Music is paused", even with its output running.

**Trigger v2 (armed by output restart or com.apple.Music.playerInfo "Playing"; fires when the last
playerInfo says Playing, output has run >= 300 ms, and no playerInfo for 300 ms)**. playerInfo is a
distributed notification with Player State, Name and PersistentID; needs no permission; a pause
posts a stray "Playing" ~40 ms before "Paused", hence the settle on playerInfo too.
| Run | Switch | Trigger | Segment after the switch |
|---|---|---|---|
| fw3 | 96k -> 44.1k | 0.39 s after Playing; rebuild 0.08 s | 18.6 s, 0 dropouts, 16-bit 100.0000%, monitor == tap 100% |
| fw4 | 44.1k -> 96k | 0.44 s after Playing; rebuild 0.07 s | 13.5 s, 0 dropouts, max err 1 LSB, 24-bit 99.9046% (Music's gain), monitor == tap 100% |
The pipeline starts ~0.36 s into the new track; before that Music's own (unmuted) output plays the
start directly at the right rate. The MT 48's own restart after the switch happens while the
pipeline is torn down, so it costs the renderer nothing.

- Bug found: the playerInfo observer was registered after pipeline 1 was built, so the first
  Playing was missed and pipeline 1 kept its startup-flap dropouts (fw3 seg 1, fw4 seg 1: 913-5199
  dropout frames). Fixed in the source (observer first); **not rebuilt/tested** (needs an Allow).
- A pipeline with a muted Music tap built while Music is idle sometimes gets no IO at all for 15 s
  (fw1, p3); with Music playing it starts in ~1.2 s (p4). Another reason to build only on Playing.
- fw1 was lost to that; it was not (as first suspected) the permission prompt: TCC shows
  com.dizzysound.Renderer allowed since 16:27 and later builds didn't re-prompt.
- Analysis trap: FFT cross-correlation of unnormalized audio locked onto the wrong passage for
  segments starting mid-track (reported 0.0001% match on clean audio). segcheck.py now verifies
  the FFT offset and falls back to an exact search.

**Status**: rate-follow works in both directions when the tap is built after Music reports Playing
and its output has settled; after-switch output is bit-exact (16-bit) / Music-gain-limited (24-bit)
with no dropouts. Remaining: test the observer-order fix (startup), track changes without a rate
change, skips/seeks, and gapless album playback (does Music post Playing per track?).

## Startup fix + gapless album (trial_gapless.sh, gapless_seek.sh, gapcheck.py)
Trigger refined: a Playing notification or output restart only arms a rebuild if the pipeline is
missing, was built while Music wasn't Playing, or the device rate changed since it was built; a
"health" trigger rebuilds if Music is Playing with its output running but the tap has been exactly
0 for > 1 s (none fired). Observer registered before pipeline 1.

What Music does at a gapless track change (procwatch/playerinfo, no renderer): posts playerInfo
"Playing <next track>" (twice), but its output does NOT restart. A seek does restart it (~1 s of
on/off flapping). AppleScript `play <track>` plays just that track (no continuation, even inside a
playlist); `play <playlist>` continues, and honors that playlist's shuffle setting (was on for the
new playlist; turned off). Test used a temporary playlist "tap-test (temporary)" (Have a Cigar,
Wish You Were Here, ...), deleted afterwards.

g1 (Pink Floyd, Wish You Were Here, ALAC 96k, MT 48 @ 96k, --follow):
- Startup: Playing arrived at 2.16 s while pipeline 1 was still being built (6.8 s, stretched by
  Music's startup flapping); rebuild fired at 7.6 s. **Startup fix works.**
- Gapless Have a Cigar -> Wish You Were Here at 19.5 s: no rebuild (pipeline healthy), no health
  trigger.
- gapcheck: the tap equals the end of Have a Cigar followed directly by the start of Wish You Were
  Here (Apple's decodes concatenated) over 44.4 s: **24-bit 100.0000% match, max err 0.25 LSB,
  0 dropouts; within +-100 ms of the boundary max err 0.01 LSB.** Monitor (our output in the HAL
  mix) == tap 100.0000% over the same 44.4 s (lag 1070).
- (This album matched 100% at 24-bit, where Skyfall gave 99.90-99.92%; Music's 1 - 3.3e-8 gain
  only flips a 24-bit LSB for some sample values.)

Still untested: a mid-album change to a track at a different rate without a pause (Music
auto-advancing across rates), repeated seeks, AirPlay/other output switches, long-run drift.

## Automatic rate detection (renderer --auto; trial_auto.sh, leakcheck.py)
**Rate source**: Music logs `Input format: 2 ch, <rate> Hz, <codec> ...` (subsystem
com.apple.coreaudio, e.g. ACAppleLosslessDecoder.cpp) every time it sets up a decoder. This gives
the *real* rate of Apple Music streams (Age of Anxiety I: 96000 Hz ALAC from 24-bit source), where
AppleScript `sample rate` returns the catalog AAC's 44100. (LosslessSwitcher's fork reads the same
lines via OSLogStore for streams and asks AppleScript + the file for local tracks.) Timing, from
`log stream` + timestamped playerInfo (note: in zsh `log` is a builtin; use /usr/bin/log):
| Change | Decoder line before "Playing" |
|---|---|
| start (local 44.1k) | 71 ms |
| local -> next local (96k) | **12.1 s** (Music pre-rolls the next local track's decoder) |
| local -> stream (96k) | 63 ms (streams not pre-rolled) |
| stream -> local (44.1k) | 41 ms |
Rule used: the new track's rate = the latest decoder line seen before its (first) Playing.
AppleScript persistent-ID lookups take ~0.1 s (osascript) if ever needed.

**Switch procedure** (--auto, delay line --delay 200 ms): on Playing with a new PersistentID whose
decoder rate != device rate: mute output + clear the delay line immediately (the new track's start
is still inside it: Playing arrives ~50 ms after the boundary reaches the tap, measured in g1),
AppleScript pause + `set player position to 0`, tear down, set the rate, wait 1 s, play; the follow
trigger rebuilds the tap once Music is playing and steady. Renderer.app now also needs Automation
permission for Music (NSAppleEventsUsageDescription).

au1 (MT 48 starting at 96k; playlist Backwoods 44.1k, Skyfall 96k, Age of Anxiety 96k stream,
Backwoods 44.1k; seeks to 12 s before each end):
- Detection correct 4/4: 44.1k (83 ms before Playing), 96k (12.1 s before, pre-roll), stream 96k
  (65 ms; no switch needed), 44.1k (41 ms).
- Switches: Music paused 0.10 s after the notification, rate set and reported in 0.16 s, resumed
  1.21 s after the request (startup switch 2.7 s: it overlapped pipeline 1's slow first build).
- **No wrong-rate audio reached the output**: startup: 1.37 s of Backwoods resampled to 96k was in
  the tap, 0 output frames; Backwoods -> Skyfall: 69 ms of Skyfall resampled to 44.1k in the tap,
  0 output frames. Music was paused before each teardown, so its direct output didn't play it either.
- **Cost: a ~0.2 s silence ~0.5 s into each switched track.** After resume Music plays directly
  (right rate) until the follow trigger rebuilds (~0.4-0.5 s); the new pipeline's output starts
  empty and 200 ms behind (verified: output == tap delayed 19200 frames), so 200 ms (+11 ms) of
  silence is inserted, no audio lost. Any rebuild during music now costs this.
- Health trigger false positives: 5 fired, all on digital silence at track starts/ends (Backwoods
  has ~3 s of silence at its end), harmless there but it would cost a 0.2 s gap if it fired
  mid-music. It never caught a real failure in this run. Should be longer (3 s+) or dropped.

Options to remove the post-switch gap (untested): (a) keep Music silent between resume and the
rebuild with a separate mute-only tap, then rewind to 0:00 once the pipeline is up (needs a check
that a pipeline survives Music's seek); (b) use the 12 s pre-roll warning for local tracks to
switch at the boundary without the pause; (c) a smaller delay (notification latency ~50 ms, so
~100 ms is the floor).

State restored: MT 48 @ 96k, Music paused at 100, shuffle off, temp playlist deleted,
LosslessSwitcher relaunched.

**Requirement (Chris): no gap unless there is a sample-rate switch.** Current build vs that:
same-rate track changes and gapless albums: no pause, no rebuild (met, g1 + au1 stream->96k case).
Not yet met: the ~0.2 s delay-line silence lands *inside* the resumed track (should be inside the
switch pause); the first play after launch also costs it (startup rebuild); the health trigger
could insert it mid-music. Next build: drop the health trigger (or make it silence-safe) and move
the gap into the pause (option (a) above).

# Session 2: gap removal (2026-09-27 evening)

## Switch routine: build while playing silently, then rewind (renderer --auto; trial_switch.sh, outcheck.py)
Health trigger removed. New `--auto` behavior: no pipeline at launch; Music's volume is held at 0
until the first pipeline exists (restored on exit). On Playing with a rate mismatch *or* no
pipeline built while playing (first play after launch), the "switch routine" runs: mute our output,
pause Music, note its position, volume 0, tear down, set rate, play (silently), wait until Playing +
output steady 300 ms, build, restore volume, then `--rewind pause` (default): pause, set position
to where this play started (0 for a new track), wait until the tap has been exactly 0 for 100 ms,
unmute, play. The delay line's 200 ms now falls inside the pause. `outcheck.py` follows the
*output* (not the tap): runs of signal, where each starts in the source, continuity, dropouts, and
wall-clock silences between runs (cycles.txt now carries each cycle's host time).
The ad-hoc build did not need a new Allow (TCC kept the grant).

sw1 (device at 44.1k at launch; playlist Backwoods 44.1k, Skyfall 96k, Age of Anxiety stream,
Backwoods; 4 s user pause at ~8 s; seeks to 12 s before each end):
- **First play after launch: fixed.** Routine 3.6 s from Playing to resume (pipeline 1's first IO
  took 1.6 s). Output starts at the source's first signal (Backwoods has 0.167 s of leading digital
  silence), contiguous, 16-bit exact, 0 dropouts. Nothing was audible before (volume 0).
- **Pipeline built while playing survives pause -> set position -> play**: every run after a
  rewind is contiguous with 0 dropouts; switched tracks start at source 0.000 s. The only non-exact
  audio is Music's own ~25-36 ms fade-in after play (and ~25 ms fade-out on pause), same as any play.
- **User pause/resume (4 s) with the pipeline up: no rebuild, 0 dropouts.** Music itself skips
  ~0.1 s across a pause (output ends at source 4.123 s, resumes at 4.226 s): Music's behavior.
- **Switch 44.1k -> 96k failed to hold**: after `play` Music's output never ran; Music paused
  *itself* 3.8 s later; the hold timed out at 10 s -> 12 s gap. The MT 48 coming up at 96k (known to
  take up to ~8 s). Fix (next build): LosslessSwitcher's settle logic (f71e242: SilentOutput
  keep-alive IOProc while paused + waitUntilReady: running 0.5 s, measured clock within 0.5%,
  restart keep-alive if it keeps stopping), and re-`play` if Music pauses itself during the hold.
- **Stream detection picked the wrong rate**: Age of Anxiety first set up a *lossy* 48k decoder
  (AAC), switch went to 48k; the lossless 96k decoder line came 2.5 s later (after our replay), so
  the rest of the track was resampled to 48k. (In au1 the same stream came up lossless at once.)
  Fix: a lossless line within 10 s of a track detected from a lossy line triggers another switch.
- Switch 96k -> 48k (the wrong-rate one): 2.59 s from the end of Skyfall's output to the next
  track's first output (was ~1.4 s + 0.2 s mid-track in au1). switchwait (1 s) is now 0: the
  readiness wait replaces it.

## Settle wait from LosslessSwitcher + stream upgrade rule (trial_switch2.sh)
Chris pointed at the settling work in the LosslessSwitcher PRs (branch local-file-detection-research,
c5ce9f5 / f71e242). Ported: while Music is paused, a SilentOutput IOProc keeps the MT 48 running so
it restarts at the new rate; resume only when it has run 0.5 s at the new nominal rate with the
measured clock (kAudioDevicePropertyActualSampleRate) within 0.5% (2 s fallback), restarting the
keep-alive if it keeps stopping after 2.5 s. The keep-alive runs until the pipeline is built.
`--switchwait` now defaults to 0 in --auto. Also: re-`play` if Music pauses itself during the hold;
a lossless decoder line within 10 s of a track detected from a lossy one triggers another switch.

sw2 (device at 48k at launch; playlist Backwoods 44.1k, Skyfall 96k, Have a Cigar 96k, Wish You
Were Here 96k, Age of Anxiety stream, Backwoods 44.1k; 10 s user pause; seeks/skips per the script):
| Event | What happened | Output (outcheck / gapless check) |
|---|---|---|
| first play, 48k -> 44.1k | ready 2.34 s after the set (actual 44264.7), hold 0.3 s, pipeline 1 first IO 1.44 s; 4.77 s request -> resume | from the source's first signal, contiguous, 0 dropouts |
| 10 s user pause (Music's output stopped at 18.5 s, restarted on play) | no rebuild | contiguous after resume, 0 dropouts (Music's own ~0.1 s skip across a pause, as in sw1) |
| 44.1k -> 96k at Backwoods' end | ready 2.20 s after the set (actual 95739.2); 3.16 s request -> resume | Skyfall from 0.000 s, 7 ms start transition, 0 dropouts |
| skip Skyfall -> Have a Cigar (same rate) | no routine, no rebuild | 0.098 s silence = Music's skip fade; Have a Cigar from 0.000 s |
| gapless Have a Cigar -> Wish You Were Here | no routine, no rebuild | output == Apple's decodes concatenated: max err 0.25 LSB@24, 0 frames > 1 LSB, boundary +-100 ms max 0.01 LSB, 0 dropouts |
| skip to Age of Anxiety (stream, came up lossless 96k) | no routine | (no source file) |
| 96k -> 44.1k at the stream's end | ready 2.79 s after the set; 3.78 s request -> resume | Backwoods from its first signal, 0 dropouts |
The sw1 44.1k -> 96k failure did not recur (1 of 1; LosslessSwitcher saw it 3/5 before the keep-alive
restart and 0/12 after). The lossy->lossless upgrade path was **not exercised** (the stream came up
lossless at once this time).

**Against the requirement:** no pause or silence anywhere without a rate switch (same-rate skip,
gapless, user pause/resume, first play without a rate change only delays the start); every switched
track starts from its first sample. **Cost:** a rate switch is now a ~3.2-4.0 s pause (was ~1.2 s +
0.2 s inside the track), mostly the device readiness wait (2.2-2.8 s on the MT 48), then hold
0.3 s + build + rewind ~0.5 s + the 200 ms delay line. First play after launch: ~3.6-4.8 s from
pressing play to sound (pipeline 1's first IO is slow, 1.4-1.6 s).
Task 4 (use the 12 s decoder pre-roll to switch at the boundary) not attempted: the device still
needs its ~2.5 s to settle at the new rate, so knowing the rate early can't remove the pause; it
could only skip the pause/rewind dance, which already costs no audio.

State restored: MT 48 default @ 44.1k (as found), Music paused at 100, shuffle off, temp playlist
deleted, LosslessSwitcher relaunched.
Temp playlist for trial_switch2.sh (delete after): `make new user playlist with properties
{name:"tap-test (temporary)"}`, then `duplicate (first track of library playlist 1 whose persistent
ID is pid) to p` for A485A3F165BE6CC2, C79A30CC28CE5BF7, FC3BD926B8276552, 6B4EB2B50BF782DD,
77AC8F0632ECBA3F, A485A3F165BE6CC2 (trial_switch.sh: without the two Pink Floyd IDs).

## Repeated switches incl. 48k and 192k (trial_rates.sh; 2026-09-27 ~17:10-17:40)
MT 48 rates: 44.1/48/88.2/96/176.4/192k. Tracks: Bobby's Song (The Aliens, ALAC 48k,
58283B44B419F777), Ventura Highway (America, ALAC 192k, AE57AD96DC95CAB1). Playlist (temp):
Backwoods, Skyfall, Backwoods, Skyfall, Backwoods, Skyfall, Bobby, Ventura, Backwoods, Ventura, Bobby
-> 10 switches per run: 44.1->96 x3, 96->44.1 x2, 96->48, 48->192, 192->44.1, 44.1->192, 192->48.
trial_rates.sh seeks 8 s before each end, waits for the next track, lets it play 12 s.

**sr1** (build of session 2): readiness 1.58-2.57 s for 9/10; the first 44.1k->96k stalled
("device keeps stopping", 3 keep-alive restarts, not ready at the 8 s timeout -> switch took 10.4 s;
Music then played fine). The other two 44.1k->96k: 2.1 s (clock never measured -> 2 s fallback).
48k: 1.58/1.62 s (clock measured at once, 48000.4). 192k: 2.42/2.47 s ("ready after 4-10 starts").
outcheck: every switched track from its first sample, 0 dropouts, only Music's 4-9 ms start fades.
**But a leak**: Music posted Playing 455-722 ms after the old track ended in the tap (au1 saw ~50 ms);
the next track's audio starts ~320 ms after that end, so twice (-> 96k, -> 192k from Backwoods)
90 ms / 148 ms of the next track resampled to 44.1k reached the DAC (peak 0.0004 / 0.093).

**Boundary latch** (fix): every one of sr1's 10 boundaries has >= 82 ms of exact zeros in the tap
between the old track's end and the new track's audio. A decoder line for a rate != the device's
while a pipeline plays (local pre-roll 8-12 s ahead; streams ~60 ms ahead) arms a latch for the old
track's last 1.5 s (AppleScript position/duration); the IO thread then stops feeding the delay line
at >= 10 ms of exact zeros. The old track's tail keeps playing out of the delay line; on Playing the
line isn't cleared, and the routine waits for the tail to drain before tearing down. Same-track
playerInfo (seek/pause) disarms/releases; unused arm expires after 5 s, a latch after 4 s.

**sr2** (latch build): all 10 switches latched (62-306 ms before Playing, or ~2 s early on
Backwoods' trailing digital silence); no stalls (44.1k->96k ready 2.09-2.37 s, 3/3).
outcheck: **no leak** (no output between the old track's end and the switch); every old track
plays to its last sample (Skyfall to 286.081 s, Bobby to 624.225 s, Ventura to 213.367 s = the
files' durations); every new track from its first sample; 0 dropouts; 16-bit exact apart from
Music's fades. Switch pause: 2.6 s (-> 48k) to 3.5 s request -> resume.
**Except segment 10 (44.1k -> 192k, Ventura): Music's audio itself was wrong.** Output == tap
delayed 200 ms exactly (renderer fine), but tap != source: time-aligned (constant lag 478 frames,
no drift), correlation only ~0.3, not a gain, not a channel/lag mix (least squares residual 95%),
no 512-frame block matches the source, and image-like energy above 22 kHz (24-40k at -20 dB vs
-58 dB in segment 8, same track). Music's log shows its mixer at 192k in and out for both switches
(no SRC in Music's chain). The one difference found: readiness accepted the clock at 191146.8 Hz
(0.44% off, inside the 0.5% tolerance); every other 192k switch was within 10 ppm. Not understood;
1 of 22 switches over sr1+sr2 (sr1's 44.1k -> 192k was clean). Traced, not reproduced.

**sr3** (latch build; temp playlist alternating Backwoods 44.1k / Ventura 192k, 9 switches):
readiness 1.86-2.58 s, no stalls, 192k clock measured at 192001.1 Hz every time. outcheck: all 9
clean (no leak, old tracks to their last sample, new tracks from their first, 0 dropouts); the
segment-10 corruption did not recur.

**Tally over sr1-sr3 (29 switches, startups excluded):**
| Change | n | Result |
|---|---|---|
| 44.1k -> 96k | 6 | 5 clean in 2.1-2.4 s; 1 MT 48 stall (keeps stopping, 3 keep-alive restarts, 10.4 s), audio then clean |
| 96k -> 44.1k | 4 | clean |
| 96k -> 48k | 2 | clean (fastest: readiness ~1.6 s) |
| 48k -> 192k | 2 | clean |
| 192k -> 44.1k | 6 | clean |
| 44.1k -> 192k | 7 | 6 clean; 1 (sr2) got non-bit-perfect audio from Music, readiness had accepted a clock 0.44% off |
| 192k -> 48k | 2 | clean |
Leaks: 2 in sr1 (before the latch), 0 in 19 with it. Candidate follow-ups: tighten the clock
tolerance above 96k (e.g. 0.05%) and see whether the 44.1k -> 192k corruption ever recurs.

State restored: MT 48 @ 44.1k, Music paused at 100, shuffle off, temp playlist deleted,
LosslessSwitcher relaunched.

## Tighter clock tolerance above 96k (sr4; 2026-09-27 ~18:15-18:25) -> hypothesis refuted
Change: above 96k the readiness wait needs the measured clock within 0.05% (`--hightol`, percent),
and the 2 s steady fallback only applies if the HAL never measured the clock (sr2's bad switch was
accepted at 1.97 s, before the fallback, so the tolerance alone was the knob). <= 96k unchanged
(at 44.1k the MT 48 measures 0.27-0.43% off even on bit-exact switches).
Note: this build needed new Allow clicks (TCC keeps the grant per build); the first sr4 attempt ran
with prompts pending: no IO (first IO cycle after 15 s) and AppleScript blocked 60-84 s. Aborted,
Music volume restored, Chris clicked Allow on a 40 s warm-up run, then sr4 ran.

sr4 (playlist Backwoods, Ventura, Bobby, Ventura, Skyfall, Ventura, Backwoods, Ventura, Bobby,
Ventura, Skyfall, Ventura: 11 switches, 6 into 192k from 44.1/48/96k x2):
- All six 192k readiness waits measured 192001.2-192001.3 Hz (6-7 ppm); the tighter tolerance never
  held a switch back (no "waited past the 0.5% point" line).
- 192k -> 96k (switch 5): MT 48 stall again (38 starts, keep-alive restart, NOT ready at 8 s; 9.6 s
  switch). The other 192k -> 96k: ready 1.9 s.
- outcheck: 11 latched, no leaks, all tracks from first to last sample, 0 dropouts - **except
  segment 6 (96k -> 192k, Ventura): the same corruption as sr2 segment 10** (24-40 kHz at -24 dB vs
  -58 dB in good 192k segments; output == tap delayed exactly, so it's Music's audio), with the
  clock measured at 192001.3 Hz. **The clock-offset hypothesis is refuted.**
- Totals into 192k (sr1-sr4): 2 of 13 corrupted (from 44.1k in sr2, from 96k in sr4). sr4's came
  right after the 192k -> 96k stall; sr2's didn't follow a stall. Cause still unknown. The -58 vs
  -20 dB energy above 24 kHz separates bad from good segments of this track cleanly, but that's a
  property of this 192k recording, not a general detector.

## Checkpoint: Music's log for the bad 192k switch (sr4 switch 6) vs good ones (2026-09-27 evening)
`log show --predicate 'process == "Music"'` (~3000 lines per switch window), bad sr4 switch 6
(96k -> 192k) against good switch 12 (96k -> 192k, last track) and good switch 4 (48k -> 192k,
with a next track, like the bad one). t0 of sr4 = 18:15:59.3 local.
- Ruled out: **Music's effects** (EQ/Sound Enhancer/crossfade tap): every item logs "0 effects
  enabled" (soundEnhancerAmount = 0; a diff that stripped digits first suggested otherwise).
  **Music-side SRC**: MEMixerChannel "Proposed input/output format 2 ch, 192000 Hz" in all.
- Same in bad and good: AudioQueue restart, time-stretcher "SchedTimePitchAddRateChange 1.000",
  "TimePitchProperty set qtpb: 0", itemoverlap "TimePitchAlgorithm set" on the pre-rolled next item,
  ResumeIO sequences.
- Only in bad (1 line): `HALC_ProxyIOContext::IOWorkLoop: skipping cycle due to overload` at
  18:17:46.964, ~0.3 s after our pipeline build / volume restore. Good switch 12 instead logged a
  burst of MT 48 "Abandoning I/O cycle because reconfig pending". One line isn't a cause; an
  overload would drop a cycle, not alter a whole track.
- The corruption lasts for the whole item (both runs in segment 6: start and the seek to 205 s) and
  is gone on the next item: an item-level state, consistent with e.g. a time-pitch unit not
  bypassed at rate 1.0 (aligned, correlation ~0.3, HF artifacts) - a hypothesis, not observed.
Next: reproduce without the renderer (LosslessSwitcher-style switch or just `audioctl set-rate`
+ play, capture with a plain unmuted tap) to learn whether our pause/volume-0/rewind sequence
triggers it; test whether pausing -> play again (new AudioQueue) clears it.

## 192k corruption without the renderer (repro192.sh / repro192.py; 2026-09-27 ~18:45-19:05)
repro192.sh switches into 192k the way LosslessSwitcher's pause-while-switching does, with no
renderer: device set to the from-track's rate, play it 3 s, start Ventura (Music begins it at the
old rate), pause 0.2 s later, `audioctl set-rate 192000`, wait 3.5 s, rewind, play; 1.5 s later
the spike's TapCapture.app (unmuted device tap; still granted from 15:46, no new Allow) records
5 s. repro192.py locates the capture in the 192k source and measures 24-40 kHz energy.
- **rp1 (plain), 12 rounds from 44.1/48/96k x4: 0 corrupted**; every capture 24-bit exact
  (100.000% within 1 LSB), 24-40 kHz at -58 dB.
- **rp2 (+ the renderer's volume sequence: volume 0 before the rate set, play silently 0.9 s,
  volume 100, pause, rewind, play), 12 rounds: 0 corrupted**, all 24-bit exact.
  (Harness trap: one AppleScript `pause` + `set player position` + `play` leaves Music paused; the
  first rp2 attempt captured silence 10/12 times. Separate calls, as the renderer makes, work.)
- 0/24 without the renderer vs 2/13 with it: if the rate were the same (~15%), 24 clean rounds
  would happen ~2% of the time. So the renderer most likely contributes. Left to bisect (each needs
  a build + Allow and ~25 switches for a 15% effect): the SilentOutput keep-alive IOProc during
  the rate change and hold; the muted Music tap + aggregate on the device (built while Music plays);
  the monitor tap. (--mute unmuted exists but plays Music twice, 11 ms apart.)

## 192k corruption: bisect (trial_192.sh / sr192.py; 2026-09-27 ~18:55-19:50)
Build with `--nokeepalive` (no SilentOutput; fixed 3.5 s wait after the rate set) and `--taponly`
(records only the Music tap, for 340 s runs). trial_192.sh: temp playlist (Backwoods 44.1k, Ventura
192k, Bobby 48k, Ventura, Skyfall 96k, Ventura) x4 -> up to 12 switches into 192k per run; seek to
4 s before each end, play 6 s. sr192.py: for each 192k segment, 24-40 kHz energy of Music's tapped
audio 0.5-2.5 s after its first signal (clean ~-58 dB, corrupted -19..-31 dB) and a sample-exact
search in the source (validated: flags exactly sr2 seg 10 and sr4 seg 6).
| Variant | Runs | Corrupted / switches into 192k |
|---|---|---|
| full renderer (monitor tap on), earlier runs sr1-sr4 | 4 | 2/15 |
| --nokeepalive (monitor on) | nk_a, nk_b | 1/20 (48k -> 192k, an ordinary switch) |
| full renderer, interleaved | fu_a, fu_b | 3/22 |
| --nomonitor | nm_a, nm_b, nm_c, nm_d (c, d interleaved with fu_a, fu_b) | **0/42** |
| no renderer (repro192.sh, unmuted TapCapture) | rp1, rp2 | **0/24** |
With the monitor tap 6/57, without it 0/66: one-sided Fisher p = 0.009 (0.03 on renderer runs
alone). **The monitor tap is the trigger** (confirmed statistically, mechanism unknown): a second
process tap on the same device stream, CATapDescription(excludingProcesses: [Music]), occasionally
corrupts Music's own audio for a whole 192k item (Music's log showed an IOWorkLoop "skipping cycle
due to overload" only in the bad switch). The keep-alive is not needed for it (nk_a). The monitor
was only a verification instrument (output in the HAL mix == tap); output == tap delayed is still
checked from the IOProc's own output. **Change: the monitor tap is off by default in --auto
(`--monitor` enables it).** Rebuilt; the next launch needs Allow.
Side note: without the keep-alive, a fixed 3.5 s wait once let Music pause itself during the hold
(the retry recovered it); the MT 48 also stalled at 96k several times (NOT ready at 8-11.5 s).

Reverted the --hightol change (Chris): readiness is LosslessSwitcher's again (0.5% at every rate,
2 s steady fallback). It never held a switch back in sr4 and the corruption turned out to be the
monitor tap.

## Closing the gap to LosslessSwitcher (tr1; 2026-09-27 ~20:35)
Trims to the routine after the device is ready (readiness itself unchanged, LosslessSwitcher's
logic): hold settle 300 -> 120 ms (--settle), volume restored while Music is paused for the rewind
instead of 150 ms before the pause, tap-quiet wait 100 -> 40 ms (--quiet). gapparts.py itemizes
each switch (request -> ready, ready -> unmute, Music's play -> first sound in the tap, delay line).
Same playlist and script as sr2 (trial_rates.sh), monitor off.
| | sr2 (before) | tr1 (after) |
|---|---|---|
| ready -> unmute | 0.78-0.85 s | **0.31-0.33 s** |
| Music's play -> first sound | ~0.2 s (0.35 s on Backwoods: 0.167 s of leading silence) | same |
| silence, old track's end -> new track (not after Backwoods' 3 s trailing silence) | 2.93-3.88 s | **2.37-3.67 s** |
tr1 per switch (silence): -> 44.1k 3.27/3.31 s, -> 48k 2.47/2.37 s, -> 192k 3.67 s (readiness
2.79 s). outcheck: every track from its first sample, start transitions 0-9 ms as before (the
volume restore while paused adds no fade), 0 dropouts, no leaks. One MT 48 stall (switch 2 ready
4.85 s).
vs LosslessSwitcher on the MT 48 (its log, Normal gap 0.25 s): resumed 2.1 s (48k) - 2.7 s (44.1k)
after the track start, plus Music's ~0.2 s play latency -> ~2.3-2.9 s to sound. The renderer is now
within ~0.1-0.4 s of that; what remains is the 200 ms delay line and the 0.32 s routine.

# Fork: LosslessSwitcher + renderer (2026-09-27 evening)
Decision (Chris): fork LosslessSwitcher with the renderer as an output engine, then a virtual
device for hog mode. Branch `renderer-engine` of dizzysound/LosslessSwitcher (worktree
~/Developer/LosslessSwitcher-renderer, from local-file-detection-research; commit 1b7dd85):
Quality/RendererEngine.swift (this prototype's --auto, minus the monitor tap and experiment flags,
on its own thread, reusing LosslessSwitcher's SilentOutput / waitUntilReady / suitableFormat /
apply), menu toggle "Renderer Engine (Experimental)". Notes and traps:
research/renderer-engine/log.md there. trial_ls.sh here drives "LosslessSwitcher Dev" with the
engine and its debug recorder (same file format, so outcheck.py / gapparts.py / sr192.py work).
- ls1 (10 rate switches incl. 48k/192k) and ls2 (mixed: first play, 10 s pause, same-rate skip,
  gapless, stream, switches): all clean by outcheck (first to last sample, 0 dropouts, no leaks;
  gapless 0.25 LSB max), 0/2 192k segments corrupted, request -> audible 2.5-3.4 s.
- New trap: tccd asks the app for **Microphone** when the tap + aggregate are created (the
  aggregate includes the MT 48's inputs); unanswered capture prompts leave the pipeline without IO.

# Virtual output device for hog mode (branch `vdevice`, 2026-09-27 night)
Goal: Music plays to a virtual device whose clock follows the DAC; the renderer reads it and owns
the DAC (hog + non-mixable integer), so hog mode and bit-perfect output coexist.

## Plug-in: vdev/LSOutput.driver (build.sh; no Xcode here, clang + ad-hoc codesign)
Base: Apple's NullAudio sample (WWDC21 "Creating an Audio Server Driver Plug-in", MIT license,
vdev/LICENSE-NullAudio.txt; committed unmodified first, d20eff1). BlackHole (GPL) not used.
patch_nullaudio.py makes LSOutput.c from it:
- Device "LosslessSwitcher Output" (UID LSOutput_UID, bundle com.dizzysound.LSOutput), 2 ch
  float32, rates 44.1/48/88.2/96/176.4/192k (sample: 44.1/48 only), no icon advertised.
- Loopback: WriteMix stores the output mix in a 131072-frame ring indexed by sample time,
  ReadInput returns it at the same sample time and clears it (so a stopped writer reads as zeros).
- Clock: zero time stamps every 16384 frames on host(S) = anchorHost + (S - anchorSample) *
  nominalTicksPerFrame * rateScalar. Custom device property 'LSrs' (CFNumber, same meaning as
  AudioTimeStamp.mRateScalar, 0.99-1.01) sets the scalar and re-anchors at now (continuous sample
  time). 'LSst' returns a status dictionary (sample time now, scalar, loopback counters). A rate
  change re-anchors the time line and bumps the seed.
- harness.c loads the bundle in-process with a fake host and checks: name, 6 rates, 6 formats,
  custom property list, 96k config change (22.05k refused), zero stamps at nominal pace and at
  scalar 1.0005 (0 tick error), scalar 1.2 refused, status, loopback bit-exact incl. ring wrap,
  cleared after read, negative input sample time -> silence. **All pass.**

## Renderer side: vdev/vrender.swift -> VRender.app (make_vrender_app.sh)
IOProc A on the virtual device (input only; output stream usage off) -> SPSC ring (vring.h, C11
atomics) -> IOProc B directly on the DAC (optional hog, non-mixable int32; DAC inputs off), starts
playing once the ring holds --target frames (2048). Control loop every 0.5 s: phase = virtual
sample time now - DAC sample time now (from both IOProcs' time stamps), error vs the phase at
play start; LS scalar = DAC's HAL rate scalar (EMA) * (1 + err/(tau*rate) + I), clamped +-300 ppm.
--nolock leaves the scalar at 1 (measures free-running drift). Reading an input needs the
Microphone permission -> app bundle, Allow once. vcheck.py: out == in delayed (bit-exact
pass-through) + phase/fill/scalar stats + free-running drift in ppm.

## First runs with the plug-in installed (2026-09-27 ~22:04-22:20; MT 48 @ 44.1k; LosslessSwitcher quit)
Chris installed LSOutput.driver (sudo ditto + killall coreaudiod). **Ad-hoc signed plug-in loads on
macOS 26.6.2**, in com.apple.audio.Core-Audio-Driver-Service.helper (its os_log shows "initialized").
System Information lists "LosslessSwitcher Output", 2 in / 2 out, Virtual, 44100. **Music plays to
it** when it is the default output (vrender --setdefault; restored after). VRender.app got the
Microphone grant with no visible trouble (input carried Music's signal).
- **v1** (100 s, free-running scalar 1, DAC mixable): Backwoods Song. out == in delayed (4.2 M
  frames of signal, 0 differ), 0 under/overruns. outcheck vs the source: **16-bit exact 100.0000%
  from the source's first sample, start transition 0 ms**, 0 dropouts. Free-running drift virtual
  (host clock) vs MT 48: -0.26 frames/s = **-5.8 ppm** (phase error reached -22 frames in 100 s);
  the MT 48's HAL rate scalar averages 0.9999918 with 3.8 ppm sd (cycle to cycle noise).
- **v2** (740 s, locked, tau 5 s, **MT 48 hogged + non-mixable int32 16 ch**): temp playlist
  vdev-temp (Gateway), Backwoods from 380 s -> Waiting -> May Dance; later someone seeked in May
  Dance and switched Music to the Hi-Res playlist with shuffle (88.2k tracks, resampled by Music
  into the 44.1k virtual device: fine for the clock test, not source-checkable).
  **Pass-through bit-exact over the whole run** (32.4 M frames of signal, 0 differ), **0 underruns,
  0 overruns**. After 20 s: phase error mean +0.01, rms 0.78, max 2.83 frames; ring fill 2048-2560
  throughout (= the two 512-frame IO granularities). LS scalar set 0.9999942 (sd 3.8 ppm) tracks the
  DAC's 0.9999942; the HAL's own estimate of the virtual device's scalar agrees (0.9999942).
  outcheck vs sources: every Gateway run 16-bit exact from its first sample (0 ms start transition,
  0 dropouts), except Music's own 25 ms fade at each seek/skip (bad region exactly where the run
  ends/starts after a seek) and one frame in Backwoods at +45.584 s (1 frame > 1 LSB; not
  investigated). Track changes 1->2, 2->3: silence 3.37 / 3.18 s = the sources' own trailing silence
  + Music's usual inter-track handling (not a renderer gap: 0 underruns).
- UI note (Chris): VRender is LSUIElement, so nothing shows it's running; give the next build a
  Dock presence.
**Conclusion so far: hog mode + integer non-mixable on the DAC + bit-perfect Music audio works via
the virtual device, with the virtual clock phase-locked to the DAC within +-3 frames for 12 min.**
Open: rate switches (how Music reacts to the virtual device's rate change; the hold idea), latency
(ring 2048 + device buffers), volume keys (the virtual device's volume control does nothing).

## Rate switches through the virtual device (r1; trial_vswitch.sh; 2026-09-27 ~22:30)
vrender now follows the virtual device's rate: IOProc A sees the device's time line restart (the
plug-in re-anchors on a rate change) and marks that ring position; B plays up to the marker, then
the control thread sets the DAC to the new rate, waits until it's ready (nominal == rate, B cycling,
HAL scalar within 0.5%, 150 ms), and B resumes from the ring (nothing dropped: latency grows by the
DAC's switch time). Recordings stream to disk (in = Music's output as read from the device, out =
what the DAC got), segments per rate for both. VRender now shows in the Dock (Chris: no sign it
was running) and quits at the end.
trial_vswitch.sh: Hi-Res playlist (shuffle on, 12,556 tracks, 44.1-192k), a watcher polls Music
every 0.15 s and sets the virtual device to each new track's rate (after-the-fact detection, like
LosslessSwitcher); each round seeks to 5 s before the current track's end and waits 12 s.
Harness traps: `play (track ... whose persistent ID ...)` plays that one track and queues nothing
(Music stops at its end: "no item to play in AVQueuePlayer"); play the playlist itself. A play
issued within a few seconds of the default output changing can leave Music stopped: check + retry.
AppleScript `set player position to ((duration of current track) - 5)` fails; read the duration
into a variable first.
- r1: 4 switches 96k -> 44.1k -> 88.2k -> 192k -> 96k, MT 48 hogged + non-mixable int32 throughout
  (the non-mixable format follows the DAC's rate changes).
- **Music at a virtual-device rate change** (outcheck on the in recording, per rate segment): a
  0.03 s blip, ~0.1 s of silence, then Music continues the same track from where it was (source
  position ~0.93-1.04 s, the moment of the switch), **bit-exact at the new rate** (only >1 LSB
  frames: Music's own 25 ms fade at each seek). The virtual device's switch takes ~0.2 s.
- What comes before the switch is the new track's start rendered at the old rate (resampled; the
  0.69-0.83 s "not found" runs at each segment's end) -> with after-the-fact detection the first
  ~1 s of every switched track is lost, as in the tap renderer before its rewind.
- **Buffering through the DAC switch doesn't work**: the MT 48 took 1.27 / 2.72 / 1.46 / 7.79 s to
  be ready, each added to the latency (fill 1.34 -> 4.02 -> 5.41 -> 10.9 s) until the 2^20-frame
  ring overflowed (214,528 frames dropped). Music has to wait while the DAC switches.
- The MT 48's first IO cycle after hog + non-mixable at 96k came 3-5 s after AudioDeviceStart
  (B trims the startup backlog now).
Next: a hold in the plug-in ('LShd': freeze the zero time stamps so the HAL stops Music's IO, then
resume the time line where it stopped) to test whether Music simply waits; and switching the
virtual device at the track boundary from Music's early decoder line instead of after the fact.

## Hold in the plug-in: does Music wait? (h1, h2; 2026-09-28 ~05:30; plug-in reinstalled with 'LShd')
'LShd' (CFNumber): 1 = freeze the zero time stamps; 2 = request a config change (action 1) and
block in PerformDeviceConfigurationChange until released (HAL stops IO meanwhile); 3 = arm: block
inside the next rate change; 0 = release. Timeout 15 s; the time line continues from where it
stopped (seed bumped). harness.c: all hold checks pass (freeze, config hold blocks 0.40 s until the
release, property reads still work during it, armed rate change blocks until released). In the
real HAL the release from another process arrives while Perform blocks (no deadlock): config hold
of 3.000 s measured by the plug-in. Install trap: after `sudo ditto` the running helper keeps the
old code until `sudo killall coreaudiod` (check: AudioObjectHasProperty 'LShd').
vrender --hold "mode@t:dur,..." schedules holds; outcheck on the in recording (what Music wrote).
- **h1 freeze (mode 1, 3 s): Music doesn't stop.** The HAL keeps running IO on its extrapolated
  time line; after the release the loopback carried 2.6 s of corrupted audio (78% 16-bit exact,
  a 0.38 s repeat). Dead end.
- **Config hold (mode 2): Music's output stops, but Music's own clock runs on and the held time
  is skipped.** h2 (Backwoods from 60 s): 0.5 s hold -> 0.61 s silence, source skipped 0.60 s;
  1.5 s -> 1.55 / 1.55 s; 3 s -> 3.08 / 3.18 s. Each resume has an 81-93 ms start transition
  (Music fades in), one had 513 short dropouts. (h1's 3 s hold read as a 0.47 s skip; the three h2
  holds agree with each other, h1's single number is unexplained.) Music's reported player
  position advances at 1x straight through the holds.
- Conclusion: **Music can't be made to wait from the device side.** The virtual device solves hog
  mode, not the rate switch; a switch still needs Music paused and rewound (the tap renderer's
  switch routine), with the virtual device's rate change (~0.2 s) plus the DAC's (1.3-7.8 s on the
  MT 48) inside the pause.

## Virtual device + pause/rewind switch routine (vrender --auto; a1; 2026-09-28 ~05:50)
vrender --auto follows Music by itself: `log stream` of Music's "Input format:" decoder lines and
com.apple.Music.playerInfo. A decoder line for another rate while playing (the next track's
pre-roll) arms a boundary latch 1.5 s before the current track's end; IOProc A then marks the ring
at the first run of 10 ms of exact zeros (Music's inter-track zeros) and B stops there. On the new
track's Playing: pause Music (AppleScript), set the virtual device (0.015-0.018 s) and the DAC
(B keeps the MT 48 running with silence), wait until the DAC is ready (nominal, B cycling, HAL
scalar within 0.5%, 150 ms), B flushes the ring (the new track's wrong-rate start and the pause
fade are dropped: no volume games needed), rewind Music to where the play started (0 at a track
start), play; B restarts at the 2048-frame target. No latch -> cut at B's read position. Latched 4 s
without a new track -> released. VRender now needs Automation (Music) as well as Microphone.
trial_vswitch.sh with NOSET=1 (watcher only logs the tracks).
- **a1** (Hi-Res, shuffle, MT 48 hogged + non-mixable int32, 6 boundaries: 1 same-rate, 5
  switches 96 -> 88.2 -> 48 -> 96 -> 48 -> 96k): **all 5 latched at the old track's end; every
  switched track from its first sample (start transition 0-7 ms); every old track's remaining
  5.00 s played in full; no wrong-rate audio ("not found": none); the same-rate change Free Hand ->
  Disgustipated played through with no silence.** DAC output == Music's output over the whole
  first segment (1.62 M frames, 0 differ); >1 LSB frames are Music's seek fades (trial) plus 16
  frames mid-Free Hand that are in Music's own output.
- Per switch: request -> play 1.39-4.83 s (virtual device 0.02 s, MT 48 ready 1.23-4.67 s);
  silence old end -> new start 1.77 / 1.80 / 3.84 / 4.19 / 5.18 s (MT 48 time dominates; includes
  any trailing silence of the sources).
**The virtual-device path meets the requirements in this trial: hog + integer on the DAC,
bit-perfect, gaps only at rate switches.** Next: port to RendererEngine (LosslessSwitcher fork),
then longer multi-rate runs (incl. 176.4/192k, streams, user skips/pauses).

# Engine port: the virtual device in LosslessSwitcher (2026-09-28 morning, session 4)
vrender --auto ported into the LosslessSwitcher fork: dizzysound/LosslessSwitcher branch
`renderer-vdevice` (from renderer-engine; worktree ~/Developer/LosslessSwitcher-renderer),
Quality/VirtualDeviceEngine.swift. MenuBarController starts it when "LosslessSwitcher Output"
(UID LSOutput_UID) exists, else the tap RendererEngine with a log line saying the plug-in wasn't
found (defaults RendererForceTapEngine forces the tap engine). Same menu toggle, same log file
(~/Library/Logs/LosslessSwitcher-Renderer.log).
- Lifecycle: default output -> virtual device while the engine runs; the DAC is the previous default
  (or the saved UID in defaults RendererDACUID if the default already was the virtual device, or the
  built-in output). Hog + non-mixable (highest-bit non-mixable format at the rate) on the DAC. Every
  exit path (quit, toggle off, setup failure) stops IO, restores the mixable twin, releases hog,
  resets 'LSrs' and restores the default to the DAC (never to the virtual device); Music is paused
  around it and played again. At launch recoverOutput() undoes a default left on the virtual device
  by a crash. The default output changing to another device while running = the engine follows it
  (plays to it through the virtual device); the DAC disappearing = built-in output.
- The switch is vrender's (latch, pause, virtual device + DAC, flush, rewind, play) with LosslessSwitcher's
  DeviceFormat.waitUntilReady (0.5 s steady, measured clock within 0.5%, restarts B when the DAC
  keeps stopping) and its suitableFormat (nearest rate, multiples preference), limited to the
  virtual device's six rates.
- New vs vrender: a play from paused/stopped waits at a "gate" (A marks the ring at the first
  nonzero frame; B holds there) until the track's rate is known, so a wrong-rate start never reaches
  the DAC (the tap engine used volume 0 for this); B trims only zeros (startup backlog, silence
  while Music is paused); A stops filling the ring inside a switch (r1 overflowed it with 60 k
  frames of paused zeros during a 12 s MT 48 wait); a decoder line with > 13 s left in the track
  (a user skip) arms the latch at once; the PLL waits to lock until the DAC's HAL scalar is within
  100 ppm (s2: seeding on 1.00115 right after a switch walked the phase to -285 frames) and re-locks
  on a > 1000-frame jump; the ring/stamps are Swift `Synchronization` atomics (no bridging header in
  SwiftPM).
- Permissions: Microphone (NSMicrophoneUsageDescription added to Info.plist, make_dev_app.sh,
  install_app.sh; com.apple.security.device.audio-input for hardened Xcode builds) + Automation.
  Each dev build logged "not determined" then "granted" ~1-2 s later.
- Debug recording (defaults RendererDebugRecord/-Seconds) streams vrender's format to disk.
  New here: vdev/trial_lsv.sh (drives the dev app; scenarios rates / mixed), vdev/vsegcheck.py
  (out == in per rate segment, holds and flushes allowed), vdev/lsvcheck.sh (vsegcheck + outcheck
  with the watcher's files + per-lock clock summary).

## INCIDENT s1 (first run): float samples into the MT 48's int32 stream for ~6 s
B chose its sample format from the stream's virtual format read right after setting the
non-mixable physical format; it still said float32 (flags 9), the device was already int32 (76).
From the first play (7.9 s) to the stop (14 s) B wrote float bit patterns into integer samples:
loud harsh noise at roughly -6 dBFS. Fix: B is muted (format 0) until the virtual format agrees
with the physical one (equal when non-mixable; float32 at the rate when mixable); listeners on the
stream's virtual + physical formats mute B at once if what B writes no longer describes the
buffers; the engine re-checks every second. Verified silently before the next audio run
(B writes int32, flags 76), and every later run logged int32 after each switch.

## s2, r1: rate switches through the dev app (Hi-Res temp playlist "vdev-rates (temporary)")
- s2 (2 boundaries + first play): as below; found the PLL seeding problem.
- **r1** (10 boundaries incl. 3x 176.4k, 3x 192k; MT 48 hogged, int32 non-mixable throughout):
  vsegcheck **bit-exact pass-through, 16.7 M frames, 0 differ**; outcheck: every switched track
  from its source's first signal, every old track played to its end (the trial seeks to 6 s before
  it), 0 dropouts, 0 underruns; frames > 1 LSB@24 only in Music's 25 ms seek fades. (Unsleep's
  "184 ms start transition" is <= 1.5 LSB24 at -1.7 dBFS: Music's 1 - 3.3e-8 gain near full scale,
  not a fade.) First play: held at the gate 0.17 s, then switched.
  Silence old end -> new start 2.5-6.7 s, one 12.6 s (switch 9: MT 48 NOT ready within 12 s);
  "DAC keeps stopping; restarting B" in about half the switches. MT 48 ready 1.6-6.3 s.
  Clock: after lock max |err| 0.06-12.6 frames per lock (5+ s after locking).

## m1-m3: mixed use (first play, pause/resume, seek, user skip, auto boundary, Apple Music stream, gapless)
- m1: pause/resume and a seek: no switch, no renderer silence (out == in; the 0.1 s at a seek and
  ~47 ms skipped at a pause/resume are in Music's own output). User skip ("next track"): the decoder
  line came 0.25 s before Playing with 185 s left -> latch armed at once, caught Music's
  inter-track zeros -> switch with nothing of the new track at the old rate. **Bug: the stream got
  no switch**: it posted Playing before its decoder line, the previous track's 20 s old pre-roll
  line (192k) was taken for it, and the stream's own 48k lossy line was then read as a skip. Fixed:
  a line counts for a new track only if it came after the previous track began; none -> hold at
  the gate up to 3 s for it; no latch arming within 2 s of a track start or with an upgrade pending.
  (No lossless upgrade came within 25 s in m1; m2/m3 the same stream came up 96k lossless at once,
  so the upgrade path is still untested on this engine.)
- m2 (fix in): the stream held at the gate 0.40 s until its line (96k lossless), no switch needed.
  **Gapless Have a Cigar -> Wish You Were Here (96k)**: one continuous run; Cigar to its last frame
  <= 0.25 LSB24, WYWH from its first frame directly after it, +-100 ms around the boundary max
  0.01 LSB24 (only mismatch: the 25 ms fade at the trial's final pause). Music logged **no decoder
  line for WYWH** (its decoder was set up when the 2-track queue started) -> added: no line -> the
  local file's own header (LocalTrack) decides; m3 used it ("file header, no decoder line").
  Harness: playing a track reference queues nothing; the gapless step plays the 2-track playlist
  and retries until shuffle puts Have a Cigar first.
- m1-m3 pass-through bit-exact (13.6 M, 11.2 M, 8.9 M frames); 0 underruns.
- **m3: the default output was the virtual device again after quit.** The engine restored the MT 48
  (status 0) but coreaudiod's DefaultDeviceManager, re-evaluating after the hog release/format
  change 48 ms later, still had LSOutput_UID as preferred[0] for output (the preference update is
  asynchronous; the persisted list in /Library/Preferences/Audio/com.apple.audio.SystemSettings.plist
  had MT 48 first again after the next run) and put it back. Fix in the engine: hold the restore
  for 3 s (re-set if it flips). Risk that remains: while the engine runs (or after a crash) the
  virtual device is the preferred default, so a reboot/device change can pick it with nothing
  reading it = silent Mac until LosslessSwitcher launches (recoverOutput). Proper fix, needs a
  plug-in reinstall: the plug-in reports kAudioDevicePropertyDeviceCanBeDefaultDevice = false
  unless the renderer marks it active (custom property, cleared when the client goes away).
- r2 (16 rounds): **startup bug**: the MT 48 took 12.6 s to be ready at setup, Music started
  meanwhile, and B (muted until the format was confirmed) returned before touching the ring:
  327 k frames overran and the first switch's boundary was never "reached"; the inbox also handled
  Playing before the decoder line that preceded it. Fixed: gate closed before IO starts; a muted B
  still runs the ring logic and writes zeros; notifications and decoder lines handled in arrival
  order; a gate held > 0.5 s while Music plays restarts the play (flush + rewind, no device change)
  instead of keeping that latency. Otherwise r2: 7 switches clean, pass-through bit-exact 32.1 M
  frames; its last 206 s were the harness seeking inside I Hear A Rhapsody (Music's database says
  44.1k and has the duration wrong; the file is 96k: removed from the temp playlist; lsvcheck now
  takes rates from afinfo).

## Open questions
- **Latency**: Music -> A 1-2 x 512 frames (virtual device: safety offset 0, latency 0), ring
  1536-2048 (target 2048), B 512 + MT 48 safety 50 + latency 60 -> ~3.0-3.5 k frames = 70-80 ms at
  44.1k, 16-18 ms at 192k (~57-66 ms more than Music straight to the MT 48 at 44.1k). A gate hold
  adds its length (85-170 ms measured) until the next pause trims it. Options: target 1024
  (margin vs 512-frame IO granularity untested); report the latency from the plug-in
  (kAudioDevicePropertyLatency) so video apps keep A/V sync.
- **Volume keys**: the virtual device's volume control reads 0.0 (the menu-bar slider shows 0) and
  does nothing. The MT 48 has no hardware volume or mute, so there is nothing to forward here.
  Chris: some DACs have volume/mute and will need the virtual device's volume/mute forwarded to
  them; bench test later. Doing it in the plug-in (scaling) would break bit-perfect below 100%.
- **Plug-in install/uninstall**: ship LSOutput.driver in the app's Resources; menu items
  "Install/Remove Virtual Output" run ditto / rm + `killall coreaudiod` with administrator
  privileges (one password prompt; all audio restarts). Ad-hoc signed loads on macOS 26.6.2;
  distribution wants Developer ID + notarization. Uninstall must first stop the engine (restore
  default, release hog). The fallback to the tap engine when the device is missing is wired but
  was not exercised (removing the plug-in needs sudo).
- MT 48 readiness dominates the switch gap: 1.6-6.3 s typical, 12+ s twice (r1 switch 9, r2
  setup); DeviceFormat.waitUntilReady restarts B when the device keeps stopping in about half the
  switches. Whether those restarts help or prolong it is untested.

## r3, m4: final build (renderer-vdevice after the r2 fixes)
- **r3** (12 rounds, 8 switches over 44.1-192k): pass-through bit-exact 13.9 M frames, 0 underruns,
  **0 overruns**, every switched track from its first signal, every old track to its end. The app
  took ~30 s to launch (trial timed out waiting and played Music straight to the MT 48), which
  exercised **engine start while Music plays**: pause, take over, play, rate from the file header
  (no decoder line after the engine started), switch to 176.4k. Music logged no decoder line after
  the previous track began for 4 tracks here (file header decided; all right rates). Consequence:
  such a boundary can't be latched ahead; if it also changes rate, the switch cuts at the play
  position (a wrong-rate start of up to the Playing latency minus the ring could be heard). Not
  seen in r3 (those were same-rate or latched), open.
- **m4** (mixed): all clean, pass-through bit-exact 9.9 M frames; **the Apple Music stream started
  lossy 48k -> switch to 48k, then its lossless 96k decoder -> "lossless upgrade" switch**
  (the upgrade path works on this engine); gapless pair via the file-header path; restore at quit
  needed **1 re-restore** (coreaudiod flipped the default back again) and ended on the MT 48.
- Per switch across r1-r3: request -> Music playing again 1.7-6.8 s, dominated by the MT 48
  (ready 1.6-6.3 s, 12+ s twice). Clock after lock: max |err| 0.06-21 frames (5+ s after
  locking), never near the 1536-frame margin; 0 underruns in every run.

**Status: the virtual-device engine in LosslessSwitcher meets the requirements in these trials:
hog + integer non-mixable on the DAC, bit-exact pass-through and bit-perfect from each track's
first sample, gaps only at rate switches, gapless and same-rate boundaries untouched, stream +
lossless upgrade handled, DAC and default output restored on quit.** Open: see "Open questions"
above plus the unlatchable-boundary case and the CanBeDefault plug-in change.

# Plug-in default-device fix, names, install/uninstall (2026-09-28 late morning, session 4b)
Chris: do the CanBeDefault fix (he runs the sudo); latency fine; volume keys on the pastor
MacBook later; install/uninstall + simpler names in Audio MIDI Setup needed; unlatchable boundaries
(shuffled tracks from gapless albums) rare; MT 48 switch time is an outlier.
Plug-in source now canonical in the fork (HALPlugin/, bundled into the app); vdev/ mirrors it.

## Plug-in 1.1 -> 1.1.2
- 'LSac' (CFNumber): the attached renderer's pid, 0 = none. CanBeDefaultDevice: output scope only,
  only while attached; never the default input (loopback) or the alert device. The device loads
  unattached, so coreaudiod can't pick it at boot.
- Names: device/box/manufacturer "LosslessSwitcher", model "Virtual Output", channels Left/Right,
  streams Output/Loopback; output volume starts at full (the slider read 0).
- 1.1.0 cleared the attachment on RemoveDeviceClient of the renderer's pid. **r4: the HAL removes (and
  re-adds) a process's clients at a device reconfiguration**, 0.2 s after a rate change: false
  "went away" -> ineligible -> coreaudiod moved the default to MacBook Pro Speakers -> the engine
  "followed" it -> ping-pong every ~1 s (109 rate segments, underruns). 1.1.1: per-client tracking,
  detach only after the renderer has had no client for 3 s (harness: re-add within the grace keeps
  it; no client for 3 s clears it). r6 (8 switches): attachment held throughout.
- Crash tests: kill -9 of the dev app -> plug-in detached 1-3 s later. With 1.1.0 (immediate clear)
  coreaudiod moved the default to the speakers at once; with 1.1.1 (3 s grace) **coreaudiod did not
  re-pick the default when CanBeDefault turned false** (still the virtual device minutes later).
  1.1.2: after a crash-detach the device is withdrawn for 2 s (box "acquired", not persisted) so
  coreaudiod re-picks; harness: device list empty, then back 2 s later. **Not yet tested in
  coreaudiod (needs the 1.1.2 install).**
- After a kill the HAL releases hog but **leaves the MT 48 non-mixable (flags 76)**, which is also why
  coreaudiod fell back to the speakers rather than the MT 48. App side: flag
  RendererEngineOwnsOutput while the engine owns the output; at launch, if set, the saved DAC gets
  its mixable format and the default back (verified twice: "recovering the output after an unclean
  exit: DAC MT 48, mixable 0, default output (was MacBook Pro Speakers / LosslessSwitcher) 0").
- 1.1.2 also unlists the data-source ("Source 0" in Audio MIDI Setup, Chris), play-through and the
  loopback's volume/mute controls: the device publishes its 2 streams + output volume + mute.
- Engine: re-attaches every second if the attachment was lost and takes the default back instead
  of following a change it caused; reclaims the default before each play after a switch; detaches
  after restoring the DAC on a clean stop.

## Install/uninstall from the app
Menu "Virtual Output Device": status (installed version vs the one bundled in the app) and
Install / Update / Reinstall / Remove; one administrator prompt (do shell script ... with
administrator privileges: ditto + chown root:wheel + killall coreaudiod), waits for coreaudiod, the
engine is stopped around it (hands the DAC and default back) and restarted. Update 1.0.1 -> 1.1.0
and 1.1.0 -> 1.1.1 done this way (Chris entered the password; the dev app's status item sits under
the notch, clicked through Accessibility). Remove and the tap fallback: not yet exercised.

## r5: a crash (heap corruption) in the release dev app
Switch 6 of r5 (plug-in 1.1.1), during the MT 48 wait: EXC_BREAKPOINT in xzone malloc's freelist
check on a HAL IO thread (HALC_ProxyIOContext::IOWorkLoop -> operator new); the engine thread was
in a HAL property read (waitUntilReady). = the heap was corrupted earlier, cause unknown. ~45
release switches before it ran clean. ASan build (make_dev_app.sh SANITIZE=address): r6 8 switches,
no report, bit-exact 12.3 M frames, 0 underruns; r7 (20 boundaries) below.
- r7 (ASan, 20 boundaries, 12 switches): no ASan report, no crash, pass-through bit-exact 21.6 M
  frames, 0 underruns. ASan confirmed armed (ASAN_OPTIONS in the process, runtime mapped). The r5
  corruption is **not reproduced** (20 switches under ASan + r6); open.

## 1.1.2 in coreaudiod + install/remove cycle (07:13-07:20)
- Update 1.1.1 -> 1.1.2 from the menu. Controls published: output volume, output mute (+ one the
  HAL adds). Crash test: kill -9 -> 3 s later "no client for 3 s", "device withdrawn", "device back"
  2 s later -> **default moved off the virtual device** (to MacBook Pro Speakers, the MT 48 being
  non-mixable) at ~4 s. Relaunch -> "recovering the output after an unclean exit: ... default output
  (was MacBook Pro Speakers)" -> engine on the MT 48.
- **Remove** from the menu: plug-in gone, MT 48 default + mixable, engine restarted as the tap engine
  with "virtual output device not installed ...; using the process-tap engine (no hog mode)", menu
  "Not installed ... Install...", and the tap engine built its pipeline and played (switch 1 done
  2.8 s). **Install** from the menu: 1.1.2 back, the engine came back on the virtual device by
  itself. Clean quit: CanBeDefault 0, MT 48 default + mixable (flags 12).
