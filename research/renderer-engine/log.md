# Renderer Engine (branch renderer-engine)

Experimental output engine ported from the process-tap renderer prototype
(github.com/dizzysound/music-tap-spike, branch renderer; its log.md has every measurement).
Menu: "Renderer Engine (Experimental)", default off (defaults key PreferRendererEngine). When on,
the regular detection path and Pause While Switching stand down; RendererEngine owns rate switching.

What it does: Music's audio is taken by a muting process tap on the default output device and
played back to that device inside a private aggregate on the device's clock, through a 200 ms delay
line (bit-exact to the tap). A decoder log line for another rate while a pipeline plays (local next
tracks ~8-12 s ahead) arms a "boundary latch" for the old track's last 1.5 s: the delay line's
input is cut at the zeros Music leaves between tracks, so no wrong-rate audio reaches the DAC and
the old track plays to its last sample. On the new track: pause Music, SilentOutput +
waitUntilReady (this repo's settle logic), play Music at volume 0 until its output is steady (120 ms),
build the tap, restore volume while paused, rewind to where the play started, unmute, play.
Same-rate changes, gapless albums and pause/resume pass through untouched. Lossy -> lossless stream
upgrades switch again. Engine log: ~/Library/Logs/LosslessSwitcher-Renderer.log. Debug recording
(prototype format, for the research repo's outcheck.py / gapparts.py): `defaults write <bundle id>
RendererDebugRecord <prefix>` (+ RendererDebugRecordSeconds).

## Tests (2026-09-27, MT 48, LosslessSwitcher Dev via research/typecheck/make_dev_app.sh CONFIG=release)
Driven by music-tap-spike-renderer/trial_ls.sh, analysed with outcheck.py / gapparts.py / sr192.py.
- ls1 (10 switches over 44.1/48/96/192k): every switched track from its first sample, every old
  track to its last, 0 dropouts, no leaks, 192k segments clean (0/2 corrupted). request -> audible
  2.5-3.4 s (4.8-7.0 s when the MT 48 stalls). Bug found: the hold's "Music paused itself" check
  used a stale lastInfo (the inbox isn't drained during waitUntilReady) and re-sent play in every
  switch (harmless); fixed (counted from our play).
- ls2 (mixed: first play, 10 s pause, 44.1k -> 96k, same-rate skip, gapless Have a Cigar -> Wish
  You Were Here, skip to the Apple Music stream, 96k -> 44.1k): all clean; gapless in the output
  max err 0.25 LSB@24, 0 frames > 1 LSB, boundary +-100 ms max 0.01 LSB.

## Traps found
- SwiftUI may not create MenuBarController.shared (and the engine) until the menu is drawn; the
  AppDelegate now creates it at launch.
- Permissions: the engine needs System Audio Recording (NSAudioCaptureUsageDescription added to
  Info.plist, make_dev_app.sh and install_app.sh). tccd also asks for **Microphone** when the tap +
  aggregate are created (the aggregate contains the device's inputs). With the inputs switched off
  for our IOProc (kAudioDevicePropertyIOProcStreamUsage) the pipeline runs without a Microphone
  grant, but the request (and a prompt) still happens. While a capture prompt is unanswered the
  pipeline gets no IO; stopping such an aggregate hung ~105 s (now destroyed without
  AudioDeviceStop). Each ad-hoc rebuild can re-prompt.
- One launch (trial ls2 first attempt) never started the engine; not reproduced after moving the
  log first and logging each startup step.
- The `log stream` child outlives a killed app until its next write.
- A stream's mid-track lossy decoder line can arm the latch (harmless in ls2: it caught the real
  boundary); tighten to lossless lines or to the pre-roll case.

## Next
- Remove the Microphone request: an aggregate without the device's input streams, or a tap-only
  aggregate plus a separate output IOProc on the device's clock.
- Hog mode needs Music on a virtual output device driven by the DAC's clock (HAL plug-in); see the
  research repo's NEXT.md.
