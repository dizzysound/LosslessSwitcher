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

# Virtual-device engine (branch renderer-vdevice, 2026-09-28)
Quality/VirtualDeviceEngine.swift: the research repo's vrender --auto (music-tap-spike branch
vdevice, log.md "Engine port") as the engine's output path. Music plays to "LosslessSwitcher Output"
(HAL plug-in LSOutput.driver, /Library/Audio/Plug-Ins/HAL; loopback + a clock steered by the
'LSrs' rate scalar); IOProc A reads its input into a ring, IOProc B plays the ring on the DAC,
hogged, in its non-mixable integer format. MenuBarController uses it when the plug-in's device
exists; otherwise RendererEngine (process tap) with a logged reason. Defaults: RendererForceTapEngine
(use the tap engine), RendererTargetFrames (ring target, 2048), RendererDACUID (last DAC, for
recovery), RendererDebugRecord/-Seconds (streams in/out/cycles/segments/clock.csv to disk).
Needs Microphone (reading the virtual device's input) and Automation.

Traps:
- **B must not guess the DAC's sample format.** Right after the non-mixable int32 physical format is
  set, the stream's virtual format can still read float32; the first build wrote float bits into the
  MT 48's int32 stream for ~6 s (loud noise). B now stays muted until virtual == physical, and
  format listeners mute it the moment its format stops describing the buffers.
- The DAC's HAL rate scalar needs seconds to converge after a switch (1.00115 at 88.2k); the clock
  lock waits until it is within 100 ppm.
- A new track's decoder line must have arrived after the previous track began (a stream can post
  Playing first, and the previous track's pre-roll line was taken for it); a gapless successor may
  get no line at all (its decoder was set up early), so a local file's header decides (LocalTrack);
  a stream waits up to 3 s for its line, held at the gate.
- The virtual device's volume reads 0.0 and does nothing (menu-bar slider shows 0); the MT 48 has no
  hardware volume or mute. DACs that do will need the virtual device's volume/mute forwarded
  (the owner: bench test later).
- coreaudiod keeps the virtual device as its preferred default output: after the engine restored
  the DAC it put the virtual device back once (m3); the restore is now held for 3 s (m4: 1
  re-restore, ended on the DAC). A plug-in-side fix (CanBeDefaultDevice only while the engine is
  attached) is still needed for crashes/reboots.
- A play that starts while the DAC comes up (up to 12 s) waits at the gate; a muted B still runs
  the ring; a gate held > 0.5 s while Music plays restarts the play (flush + rewind) instead of
  keeping the latency.
Results (music-tap-spike log.md "Engine port"): r1-r3 25 switches incl. 176.4/192k, m1-m4 mixed use
incl. stream lossy -> lossless upgrade and a gapless pair; pass-through bit-exact in every run.

# Plug-in 1.1.2 and install/uninstall (2026-09-28 late morning)
HALPlugin/ (bundled into the app): 'LSac' attached pid; default output only while attached (3 s
grace: the HAL removes and re-adds clients at a rate change); a crash-detach withdraws the device for
2 s because coreaudiod only re-picks the default when a device goes away; names "LosslessSwitcher",
only output volume + mute published. Menu "Virtual Output Device": Install / Update / Reinstall /
Remove (one admin prompt, restarts coreaudiod; the engine is stopped around it). Launch after an
unclean exit restores the DAC's mixable format and the default (the HAL leaves a dead hog owner's
DAC non-mixable). Verified on the MT 48: update x3, kill -9 recovery, remove -> tap fallback plays,
install -> back on the virtual device. Open: one heap-corruption crash in ~45 release switches (r5),
not reproduced under ASan (make_dev_app.sh SANITIZE=address); Xcode Run Script phase untested.
Details: music-tap-spike log.md "Plug-in default-device fix".

# Bench: portable dev build (e4aff18) on the bench Mac, Babyface Pro (2026-09-28 08:03-08:15)
MacBook Pro, macOS 27.0, arm64. DAC: RME Babyface Pro, RME kext (uid de_RME_driver_USBAudioEngine:0).
- Install failed silently: the bundled LSOutput.driver carried mode 0640 on Contents/Info.plist and
  _CodeSignature/CodeResources (0751 on the binary), from the build Mac. ditto kept the modes; chown
  made them root:wheel; coreaudiod runs as _coreaudiod (other) -> cannot read Info.plist -> no
  device. The app (user) cannot read it either -> menu stays "not installed". Nothing in build.sh,
  make_dev_app.sh or install() sets modes. Workaround: chmod -R a+rX on the app's copy, reinstall
  from the menu -> device "LosslessSwitcher" (LSOutput_UID) loaded. Fix: chmod -R a+rX in build.sh
  and after chown in VirtualOutputPlugin.install.
- An engine started while the plug-in was not loaded runs the tap fallback and stays there; it
  needed a relaunch after the install.
- Babyface formats: every output stream (4/8/2 ch) offers exactly one format, float32 flags 0x1b,
  32k-192k. No integer / non-mixable format. Log: "hog DAC: 0, hogged", "DAC format -> 48000.0 Hz 4
  ch 32 bit flags 27", "B writes float32", "DAC ready after 0.505 s" (0.509 s on relaunch).
- Volume/mute controls: Babyface output has NO element-0 volume and NO mute on any element;
  per-channel VolumeScalar on el1..el6, settable, range -140..+6 dB (el1/el2 at 0.615 = -25.5 dB).
  Virtual device: el0 volume + mute, settable, range -96..+6 dB (NullAudio sample values; scalar
  1.0 reads +6 dB, one key step 0.9375 = -6.35 dB, 0.875 = -17.9 dB).
- Volume keys (posted NX_KEYTYPE_SOUND_UP/DOWN/MUTE, default = virtual device): step the virtual
  el0 scalar by 1/16 and toggle virtual el0 mute; the Babyface el1/el2 did not move. Restored 1.0/0.
- kill -9: default left the virtual device after 3.7 s, straight to the Babyface (hog -1).
  Relaunch: "at launch: recovering the output after an unclean exit: DAC Babyface Pro (73020432),
  mixable 0", re-hogged, default back on the virtual device.
- MediaRemoteAdapter's `perl run.pl ... loop` helper outlives the app after both a clean quit and
  kill -9 (two orphans seen: pids 12046, 14933).
- Rate switches (Music, tracks picked by hand, so none latched: "not latched: cut at the play
  position"): 1) 48k -> 44.1k DAC ready 1.373 s, switch done 1.564 s; 2) 44.1k -> 48k 1.385 s / 1.806
  s; 3) 48k -> 44.1k 1.389 s / 2.152 s. B float32 each time, no "B MUTED". Babyface ~1.38 s per
  switch (MT 48: 1.6-12 s). By ear (the owner): the new track played for about a second at the old
  rate before the restart. Traced (not reproduced) in the log:
  - Switch 1 held at the gate (silent as designed).
  - Switch 2 (YYZ, ~2.1 s audible): Music posted "Playing" with no name (197.737) just before
    "Playing YYZ" (197.788). The nameless one took a 44.1k decoder line that wasn't YYZ's, decided
    "same rate" and released the gate; YYZ then logged "playing on at 44100 Hz until one comes" until
    its 48k line came 2.1 s later.
  - Switch 3 (Boston, ~1.6 s audible, restart at 0.530): Music had quit ("Music quit" at 306 s);
    nothing re-armed the gate, and relaunched Music played ~1.6 s before posting Playing. The rewind
    targets the position at the notification, so 0.00-0.53 was never replayed. The rate came from a
    stale line ("seen 263.843 s before Playing", from before the quit; right by luck).
  Written (type-checked, not built): ignore a Playing with no name and no PersistentID (the next
  decoder line or 3 s decides for it); on "Music quit" re-arm the gate, wait up to 4 s for Playing,
  drop the old decoder lines; the restart point is the earlier of the Playing notification and the
  gate's first frame; a rewind target under 2 s goes to 0.
  CAVEAT: Music's AutoMix was ON for all of these runs (the owner, after the fact). AutoMix blends
  tracks, so the early decoder line (latch armed ~265 s early), the nameless Playing and the
  old-rate overlap may be AutoMix's. Rerun the switches with AutoMix off before reading more in.
- To look at: At 203 s "next track needs 44100 Hz; 265.11 s left, arming the boundary latch in 0.00 s", then
  "no boundary within 5 s; disarmed" (armed ~265 s early; Music was quit before that track ended).
- Not yet run: built-in speakers as DAC, restore on quit.
- Volume forwarding (VolumeForwarder in VirtualDeviceEngine.swift) and the chmod fix: type-checked
  on this Mac (SwiftPM with -continue-building-after-errors; a planted error in the engine file was
  reported, only QualityApp.swift's SwiftUI macros fail: Command Line Tools, no Xcode here). Not
  built or run yet: needs a build on the Xcode Mac.

# Bench: volume forwarding on the Babyface Pro (build 6c2d2ff, 2026-09-28 08:31-08:40)
Built on the Xcode Mac with make_portable_dev_app.sh, run on the bench Mac.
- Start: "volume: forwarding to DAC elements 1,2 (-41.0 dB), mute emulated (DAC has none); virtual
  volume -> 0.4598". Nothing jumped.
- Keys (posted NX_KEYTYPE events): down x2 -> DAC -50.5, -58.5 dB; up x2 -> -50.5, -43.5 dB; mute ->
  -140 dB; unmute -> -43.5 dB. macOS snaps the slider to 1/16 steps, so a start off the grid (0.4598)
  doesn't come back to itself (0.4375). One step is 8-9.5 dB on the Babyface's taper (coarse; Option+
  Shift+key gives quarter steps). The RME rounds to 0.5 dB (wrote 0.3750, reads 0.3758): inside the
  0.001 tolerance, no echo loop. Level restored to 0.4598 (-41.0 dB) after the test.
- Engine off while muted: "unmuting the DAC as the engine lets go", DAC back at -41.0 dB and the
  default. Engine on again: starts unmuted (the DAC has no mute to carry it).
- kill -9 while muted: DAC stays at -140 dB while the app is dead (nothing can run); relaunch:
  "at launch: recovering the output after an unclean exit: ... mixable 0; DAC volume restored from
  an emulated mute to 0.4598", key cleared.
- Side note: a menu click meant to turn the engine on turned it off (it was already on from the
  earlier build: same defaults domain); the stop was clean.
- dB mapping (next commit): slider linear in dB from 0 to -64 dB (4 dB per key step; defaults
  RendererVolumeTopDB / RendererVolumeRangeDB), bottom = DAC minimum, through the DAC's own
  DecibelsToScalar. The Babyface translates exactly (0 dB -> 0.9195, -41 -> 0.4598, -64 -> 0.2710, each
  round-trips). Emulated mute now restores the DAC's own scalar from before the mute. Type-checked.
- Music settings readable from com.apple.Music: TransitionsEnabled (AutoMix/crossfade; 0 now),
  TransitionStyle 1, crossfadeSeconds 1, optimizeSongVolume (Sound Check; 0), eqEnabled 1 in prefs but
  AppleScript "EQ enabled" false (prefs stale or different meaning), losslessEnabled 1,
  preferredStreamPlaybackAudioQuality 20, preferredDolbyAtmosPlaySetting 30. No Sound Enhancer key.
- New track after the relaunch took a decoder line 105 s old ("seen 105.208 s before Playing"): at an
  engine start lastNewTrackAt is nil, so any line qualifies. Same rate, harmless here.
- AutoMix off (TransitionsEnabled 0), build 6c2d2ff: "next track needs 96000 Hz; 104.88 s left, arming
  the boundary latch in 0.00 s", then "no boundary within 5 s; disarmed". The >13 s branch assumes a
  skip; Music set up the next (96k) decoder 105 s before the end, so the real boundary goes unlatched.
  The early arm seen with AutoMix on was this, not AutoMix. Fix (next commit): also arm 1.5 s before
  the end (lateArmAt), re-timed from Music's remaining time on a resume or seek.
- Music settings notifier (next commit): at engine start and each new track only (no timer, per
  the owner: minimal CPU); prefs TransitionsEnabled / optimizeSongVolume / losslessEnabled, AppleScript EQ
  enabled and sound volume; log + menu line + one notification per change of the problem set.
- Build 6c2d2ff live: "Music quit; the next play waits at the gate" (fix 2 works), but a sound right
  after the quit opened the gate ("gate released (no Playing within 4.0 s)"), and nothing closed it
  again: "new track Kashmir: no decoder line for it yet; playing on at 44100 Hz". Fix (next commit):
  after a no-Playing release, close the gate again after 0.3 s of silence (ring written - lastNZ).
  General, not only after a quit: another app's sound while Music is paused did the same.
- CORRECTION: Music never quit. `ps` shows Music pid 57518 running since 2026-09-27 18:43:48, the same
  process that logged the 96k line at 08:40:17. Both "Music quit" lines (306 s in the first session,
  386.8 s here) were false: NSRunningApplication.runningApplications(withBundleIdentifier:) returned
  empty once while Music played on (called from the engine thread; cause not established). So the
  switch 3 explanation above ("relaunched Music played before posting Playing") is wrong; what made
  Boston start ~1.6 s early is unexplained. And fix 2 turned the false quit into harm: at 386.8 s the
  gate caught Music's ongoing track and held it 4 s (a mid-track dropout), and dropping the decoder
  lines lost Kashmir's 96k pre-roll (08:40:17), so Kashmir (96000 Hz per Music) played on at 44.1k
  ("no decoder line for Kashmir within 3 s; playing at 44100 Hz").
  Fix (next commit): Music counts as quit only when its remembered pid is gone (kill(pid, 0));
  the NSRunningApplication miss is logged once.
- Build d111c36 made on the build Mac (Command Line Tools, Swift 6.3.3: builds with SwiftUI macros)
  over ssh, copied to the bench Mac (Swift 6.4 CLT: no SwiftUIMacros plugin, can't build here). The
  bundled driver is 0644 now (build.sh chmod). Old build kept as "LosslessSwitcher Dev (6c2d2ff)".
  Start: "volume: forwarding to DAC elements 1,2 (-50.5 dB), linear in dB, 0 to -64 dB (4.0 dB per key
  step) ... slider -> 0.2109"; gate held B.O.B. until its 44.1k line (0.1 s).
- The false quits on 6c2d2ff came about every 160 s (386.8, 555.8, 714.9 s), each a 4 s dropout.
- Turning the 6c2d2ff engine off: "play attempt 1-4: Music isn't playing" over 8 s, while Music
  reported playing right after. Possible gap on stop; not looked into.
- Keys confirmed by toggling (the owner, 08:53): Sound Check on -> optimizeSongVolume 1, off -> key removed;
  AutoMix on -> TransitionsEnabled 1. Notifier fired at the next track: "Music settings: AutoMix or
  Crossfade is on". The owner: the notification appeared but wants a persistent window with instructions.
  Next commit: a window listing each problem and its fix, Check Again, Set to 100 for Music's volume;
  closes itself when a check comes back clean. EQ key still unconfirmed.
