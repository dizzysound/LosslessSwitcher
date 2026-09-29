# Next step: virtual-device engine in LosslessSwitcher (branch `vdevice`)

**Status (2026-09-28, session 4):** vrender --auto is ported into the LosslessSwitcher fork:
dizzysound/LosslessSwitcher branch `renderer-vdevice` (worktree ~/Developer/LosslessSwitcher-renderer),
Quality/VirtualDeviceEngine.swift; the tap RendererEngine is the fallback when the plug-in's device
is missing. Tested through the dev app (log.md "Engine port"): r1-r3 (25 switches over 44.1-192k
incl. 176.4/192k), m1-m4 (first play, pause/resume, seek, user skip, Apple Music stream incl. a
lossy -> lossless upgrade, gapless Have a Cigar -> Wish You Were Here): pass-through bit-exact in
every run, bit-perfect from each track's first sample, gaps only at rate switches, DAC + default
output restored on quit. Tools: vdev/trial_lsv.sh <name> rates|mixed [rounds], vdev/lsvcheck.sh
<name> (vsegcheck.py + outcheck.py + clock), temp playlists "vdev-rates (temporary)" and
"vdev-gapless (temporary)" (shuffle stays on). Dev app: research/typecheck/make_dev_app.sh
CONFIG=release in the fork; each build asks for Microphone.
**Update (session 4b):** plug-in 1.1.2 (source now in the fork's HALPlugin/, bundled in the app):
default output only while the engine is attached, crash -> device withdrawn so coreaudiod re-picks,
simpler names, no dead controls; app menu "Virtual Output Device" installs/updates/removes it (one
admin prompt); unclean-exit recovery at launch (DAC mixable + default). All verified on this Mac.
**Next:**
1. The r5 crash: heap corruption seen once in ~45 release switches (malloc trap on a HAL IO thread);
   not reproduced in 20 switches under ASan. Run longer release trials; if it recurs, get a
   MallocStackLogging / guard-malloc run.
2. Volume/mute forwarding to DACs with hardware controls; Chris tests on the pastor MacBook.
3. Latency fine (Chris); unlatchable boundaries rare (shuffled gapless-album tracks); MT 48 switch
   time is an outlier (other DACs switch faster).
4. Xcode build's "Bundle HAL plug-in" Run Script phase is untested (no Xcode here); user script
   sandboxing may need to be off for it.

# Earlier: virtual device prototype (session 3)

**Status (2026-09-28 morning, session 3):** the virtual-device path works end to end in the prototype
(log.md "Virtual output device for hog mode" onward). vdev/LSOutput.driver (from Apple's MIT NullAudio,
installed in /Library/Audio/Plug-Ins/HAL) = "LosslessSwitcher Output", loopback, clock steered by the
renderer ('LSrs'), holds ('LShd', which don't make Music wait: don't use). vdev/vrender.swift ->
VRender.app (needs Microphone + Automation): Music -> virtual device -> ring -> MT 48 hogged, int32
non-mixable, bit-perfect; clock locked +-3 frames over 12 min; --auto does latch + pause/switch/rewind
(a1: 5 switches clean, same-rate seamless). Tools: vdev/build.sh (plug-in; install needs Chris's
sudo: ditto + `killall coreaudiod`, verify AudioObjectHasProperty 'LShd'), harness.c (in-process
plug-in tests), make_vrender_app.sh, trial_vswitch.sh (NOSET=1 with --auto), vcheck.py, ../outcheck.py
(for Music's own output: symlink <p>.in.f32 as <q>.out.f32 and copy <p>.in.cycles/segments).
**Next:** port vrender --auto into RendererEngine (LosslessSwitcher fork): plug-in install/uninstall
story, default output -> virtual device while the engine runs, restore on quit; then long multi-rate
runs (176.4/192k, streams + lossless upgrade, user skips/pauses). Open: latency (2048 frames + buffers),
volume keys (the virtual device's volume control does nothing), Music's 25 ms fade on seeks.

# Earlier: renderer (branch `renderer`)

Read `log.md` first: it records the spike and the renderer work so far.

**Status (2026-09-27, end of session 2):** tasks 1-3 of session 1's list done and measured (log.md,
"Session 2"). `--auto` now: no health trigger; a switch routine (pause, keep the device running
with silence until it has settled at the new rate (LosslessSwitcher's waitUntilReady), play
silently at volume 0, build the pipeline, rewind to where the play started, unmute) runs on a rate
mismatch or on the first play after launch. Same-rate skips, gapless, user pause/resume: no
rebuild, no silence. Switched tracks start from their first sample. Cost: ~3.2-4.0 s per rate
switch; ~4 s from first play to sound.

**Hard requirement (Chris): no gap unless there is a sample-rate switch.** Met in sw2 (one run).

**Update (later on 2026-09-27):** 29 switches over 44.1/48/96/192k (sr1-sr3, log.md "Repeated
switches"). Added a boundary latch (Music can post Playing 130-380 ms into the next track, past the
200 ms delay line). With it: 0 leaks in 19 switches. Open: 1 MT 48 stall (10.4 s switch) and one
44.1k -> 192k switch where Music's own audio wasn't bit-perfect (clock accepted 0.44% off; unexplained).

**Status (end of 2026-09-27):** the renderer now lives in the LosslessSwitcher fork as an opt-in
engine: dizzysound/LosslessSwitcher branch `renderer-engine` (worktree
~/Developer/LosslessSwitcher-renderer; research/renderer-engine/log.md there). Tested clean through
the dev app (trial_ls.sh; log.md "Fork").

**Next session: virtual output device for hog mode** (Chris's goal). Why: a tap needs Music playing
into the DAC's shared mix, so hog / non-mixable on the DAC and tapping Music there are mutually
exclusive (spike h2-h4). Plan:
1. Feasibility spike: an AudioServerPlugIn (HAL plug-in, /Library/Audio/Plug-Ins/HAL, needs Chris's
   admin password + `sudo killall coreaudiod`) exposing a 2 ch output device "LosslessSwitcher
   Output" at the track's rate. Start from Apple's NullAudio sample or an open-source loopback
   driver (check licenses; BlackHole is GPL).
2. Its clock (GetZeroTimeStamp) must follow the DAC's: the renderer measures the DAC's sample time
   vs host time while it plays and feeds the ratio to the plug-in (shared memory), so Music renders
   at exactly the DAC's pace -> no resampling, bit-exact. Measure drift over 10+ minutes.
3. Renderer: Music's output on the virtual device; renderer reads it (tap or the plug-in's shared
   ring), hogs the DAC, sets non-mixable/integer format, plays. Rate switch: hold the virtual clock
   (Music waits), switch the DAC, release - no AppleScript pause/rewind, no delay line needed.
4. Open questions: does Music accept a HAL plug-in device as its output (AirPlay-style menus list
   it?); latency; what System Settings shows; code signing for a plug-in on this Mac.
Also open on the fork: remove the Microphone request; tighten latch arming to lossless/pre-roll lines.

Tools: `./make_renderer_app.sh` (the last two ad-hoc builds kept the capture grant with no prompt),
`trial_switch.sh` / `trial_switch2.sh` (temp playlist: created by the AppleScript in log.md's session 2
notes, deleted after), `outcheck.py` (follows the output), `segcheck.py`, `gapcheck.py`.

## Goal
Prototype a low-level renderer that takes Music's audio from a Core Audio process tap and drives the
DAC directly, and measure whether that works and what it costs. Specifically:
1. Pass the tap's audio (Music's channels 1-2) through to the output device inside the same private
   aggregate (DAC as the aggregate's main/clock device, so tap and output share one clock), with
   Music's own output muted (`CATapDescription.muteBehavior = .muted` / `.mutedWhenTapped`).
2. Check whether exclusive access is possible for a device that's inside the aggregate: hog mode
   (`kAudioDevicePropertyHogMode`) and a non-mixable physical format (the MT 48 lists
   `kAudioFormatFlagIsNonMixable` formats, flags 76, next to the mixable ones, flags 12, at each rate).
3. Verify the output is what was tapped: record what reaches the device and null-test it against the
   tap (not against the source file; the spike showed Music itself is not bit-exact for 24-bit).
4. Handle rate changes: when Music's rate changes, the aggregate/device must follow. Note the MT 48
   takes 1.1-1.7 s (sometimes several start/stop cycles, up to ~8 s) to run again after a switch.

## What the spike established (see log.md)
- Tap = `CATapDescription(processes: [Music process object], deviceUID: <output UID>, stream: 0)`.
  Its format is the device stream's: 16 ch float32 interleaved at the device rate on an MT 48; Music
  is on ch 1-2. The aggregate's input buffers are [device inputs (8 ch), tap (16 ch)].
- Music at "100%" applies a gain of 1 - ~3.3e-8 before the tap: 16-bit sources come back exactly
  after rounding, 24-bit sources don't (0.08% of samples off by 1 LSB). A tap-based renderer can't
  be bit-perfect for 24-bit; for bit-perfect local files a renderer has to decode files itself.
- Apple Music (DRM) streams are captured normally by a tap.
- The first ~32 ms after a track starts contain a playback-start transition.

## Traps
- **Permission**: a command-line tool run from Claude Code is attributed to
  com.anthropic.claude-code and tccd refuses kTCCServiceAudioCapture with no prompt (captures are
  silent). Build the tool as an app (`./make_app.sh` -> TapCapture.app) and launch with
  `open -W -a TapCapture.app --args ...`; the user must click Allow once per build, because each
  ad-hoc signed build is a new identity. stdout is lost under `open`, so pass a log path.
- **LosslessSwitcher** (installed in /Applications, a fork with pause-while-switching) changes the
  device rate and pauses/restarts Music on track changes. Quit it during tests
  (`osascript -e 'tell application id "com.vincent-neo.LosslessSwitcher" to quit'`) and relaunch
  after (`open /Applications/LosslessSwitcher.app`).
- **Audio on Chris's Mac**: the default output is a Neumann MT 48 (USB). Tests play through it.
  Restore anything changed (output device, rates, Music volume at 100) when done.
- `audioctl` (rate / set-rate / set-default / rates) is at
  `~/Developer/LosslessSwitcher/research/local-file-resampling/audioctl` on branch
  `local-file-detection-research` of that repo (source: audioctl.swift there).
- Test tracks (Music persistent IDs): Backwoods Song ALAC 16/44.1 `A485A3F165BE6CC2`,
  Skyfall ALAC 24/96 `C79A30CC28CE5BF7`, Apple Music stream "Age of Anxiety I" 24/96
  `77AC8F0632ECBA3F`.

## Working rules
Record findings in `log.md` as you go, commit on `renderer`, push to origin (private repo
dizzysound/music-tap-spike). Checkpoint and report if 5-10 attempts at something yield nothing new.
