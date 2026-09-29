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

# Bench: portable dev build (2853f87) on the bench Mac, Babyface Pro (2026-09-28 08:03-08:15)
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

# Bench: volume forwarding on the Babyface Pro (build bab778e, 2026-09-28 08:31-08:40)
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
- AutoMix off (TransitionsEnabled 0), build bab778e: "next track needs 96000 Hz; 104.88 s left, arming
  the boundary latch in 0.00 s", then "no boundary within 5 s; disarmed". The >13 s branch assumes a
  skip; Music set up the next (96k) decoder 105 s before the end, so the real boundary goes unlatched.
  The early arm seen with AutoMix on was this, not AutoMix. Fix (next commit): also arm 1.5 s before
  the end (lateArmAt), re-timed from Music's remaining time on a resume or seek.
- Music settings notifier (next commit): at engine start and each new track only (no timer, per
  the owner: minimal CPU); prefs TransitionsEnabled / optimizeSongVolume / losslessEnabled, AppleScript EQ
  enabled and sound volume; log + menu line + one notification per change of the problem set.
- Build bab778e live: "Music quit; the next play waits at the gate" (fix 2 works), but a sound right
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
- Build a90d702 made on the build Mac (Command Line Tools, Swift 6.3.3: builds with SwiftUI macros)
  over ssh, copied to the bench Mac (Swift 6.4 CLT: no SwiftUIMacros plugin, can't build here). The
  bundled driver is 0644 now (build.sh chmod). Old build kept as "LosslessSwitcher Dev (bab778e)".
  Start: "volume: forwarding to DAC elements 1,2 (-50.5 dB), linear in dB, 0 to -64 dB (4.0 dB per key
  step) ... slider -> 0.2109"; gate held B.O.B. until its 44.1k line (0.1 s).
- The false quits on bab778e came about every 160 s (386.8, 555.8, 714.9 s), each a 4 s dropout.
- Turning the bab778e engine off: "play attempt 1-4: Music isn't playing" over 8 s, while Music
  reported playing right after. Possible gap on stop; not looked into.
- Keys confirmed by toggling (the owner, 08:53): Sound Check on -> optimizeSongVolume 1, off -> key removed;
  AutoMix on -> TransitionsEnabled 1. Notifier fired at the next track: "Music settings: AutoMix or
  Crossfade is on". The owner: the notification appeared but wants a persistent window with instructions.
  Next commit: a window listing each problem and its fix, Check Again, Set to 100 for Music's volume;
  closes itself when a check comes back clean. EQ key still unconfirmed.
- 0f8b19d: settings window opened at engine start ("AutoMix or Crossfade is on"); the owner turned the
  settings off and clicked Check Again: "Music settings: OK" at 20.3 s, window closed itself.
- Menu showed no check marks (AX: no AXMenuItemMarkChar on any item; the owner couldn't tell what was on).
  MenuBarExtra .menu drops the Image(systemName: "checkmark") in Button labels. Next commit: Toggles.
- 6652e97: menu check marks show (AX: "Renderer Engine (Experimental) | mark ✓"; unmarked items match
  the saved settings and registered defaults).
- Bench stopped by the owner (2026-09-28 ~09:00). Left running on the bench Mac: 6652e97, engine on,
  Babyface hogged, default = virtual device. Old build kept as ~/Desktop/"LosslessSwitcher Dev (bab778e)".
  Open:
  - Boundary switch with the lateArmAt fix: not yet seen (no 44.1k -> hi-res album boundary played).
  - Built-in speakers as the DAC; restore on quit with the new build.
  - The EQ preference key ("eqEnabled" 1 while AppleScript "EQ enabled" false): not confirmed; the
    notifier uses AppleScript for EQ.
  - Why NSRunningApplication lost Music every ~160 s (the pid check works around it).
  - Engine stop on bab778e: "play attempt 1-4: Music isn't playing" over 8 s; possible gap.
  - "played ~1.647 s" identical in two switches: check the tPlay estimate.
  - Dolby Atmos setting values (preferredDolbyAtmosPlaySetting 30) not decoded; not checked.
  - MediaRemoteAdapter's perl helper outlives the app (clean quit and kill -9).
  - The bench Mac's Command Line Tools (Swift 6.4) can't build the app (no SwiftUIMacros plugin);
    the build Mac's (6.3.3) can.

# Xcode build (the build Mac, Xcode 27.0 27A266a, 2026-09-28 12:45-12:55)
- The build Mac has no code-signing identities; the project's team is upstream's (3X69W4AQD6); bundle id is the
  regular app's. Built with CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= and the dev bundle id. The Run
  Script phase ("Bundle HAL plug-in") ran for the first time: driver Info.plist 0644. Universal.
  MediaRemoteAdapter_MediaRemoteAdapter.bundle is in Contents/Resources; no build path in the binary.
- First try (hardened runtime on, as in the project): dyld "Library missing" at launch: "code
  signature ... not valid for use in process: mapping process and mapped file (non-platform) have
  different Team IDs" for the embedded ad-hoc MediaRemoteAdapter.framework (library validation).
  With ENABLE_HARDENED_RUNTIME=NO it launches, also with /Users/Shared/LosslessSwitcher-dev-build moved
  aside: the setup script isn't needed for Xcode builds. (A Developer ID build needs a paid account;
  the owner's identity verification failed.)
- An iCloud-synced Desktop adds com.apple.fileprovider.fpfs / FinderInfo xattrs ("detritus" for
  codesign --strict): install bench apps in ~/Applications.
- research/typecheck/make_xcode_dev_app.sh: the bench build in one step (zip + README).
- First launch of the Xcode build on the bench Mac: while the Microphone prompt was unanswered, the
  default was already the virtual device and each HAL call on its input blocked ~60 s ("A: output
  streams off" at 90 s, "start A: 268451843" at 150 s), then "setup failed" at 210 s restored the
  Babyface: ~3.5 min of silence. After granting and toggling the engine: running normally ("start A:
  0", hogged, DAC ready 0.512 s). Open: wait for the permission answer before taking the default.

# Bench resumed on the bench Mac, Xcode build e29b8e3 (2026-09-28 13:04-13:10)
- Microphone wait (fix e29b8e3): new copy, prompt open ~23 s: "not determined; asking, and leaving the
  output alone until it is answered"; the Babyface stayed the default and un-hogged; "granted" at
  23.069, "default output -> virtual device" at 23.134, hogged 23.425.
- Built-in speakers as the DAC (default switched to them with Music stopped): "following it", hogged,
  "DAC format -> 48000.0 Hz 2 ch 32 bit flags 9" (only format offered: float 0x9 at 44.1-96k, so mixable
  float), DAC ready 0.566 s. Volume: "forwarding to DAC element 0 (-10.8 dB) ... mute to element 0"
  (real mute; the speakers' mute=1 carried to the virtual device). Keys: mute -> "mute el0 -> 0",
  one step down -> -16.0 dB (0.75 on the 64 dB window), mute -> "mute el0 -> 1". Restored -10.8 dB,
  muted.
- OPEN: on the speakers the ring sat at fill 0 ("clock lock: ... fill 0"; "48000 Hz fill 512 ... under
  6656", then "fill 0 ... under 6656"): the underruns came once, at the follow, and did not grow while
  idle, but a ring at 0 has no margin. Following back to the Babyface locked at fill 1536, so it's the
  speakers, not the follow. Not tried with music playing on the speakers.
- Restore on quit: "hog released", "default output restored to Babyface Pro", "default output after
  3 s: Babyface Pro", "engine stopped"; RendererEngineOwnsOutput cleared. Relaunch: clean start (0.5 s).
- MediaRemoteAdapter's perl helper outlived two quit copies again (killed by hand).
- Not yet: a boundary switch with the lateArmAt fix (needs an album played through a rate change).
- Fix 5969a5d (Xcode build, installed 13:09): start locked at fill 2048. Follow to the speakers:
  "clock: ring at 512 frames before the lock (target 2048); refilling first", then "clock lock: ...
  fill 2048" (was fill 0). Back to the Babyface: "clock lock: ... fill 2048". Mic wait again fine
  (answered at 3.2 s, the default taken after).
- Boundary switch, local files (5969a5d, 13:39): temp playlist "LS bench (temp)": "LSB 483 With High
  Delight Let Us Unite" (44.1k; decodes as AAC, likely the iCloud-matched copy) -> "Oh, Blest Is He That
  Came" (CPH Choral 2024, local ALAC 96k/24). "decoder: 96000.0 Hz 24-bit (lossless)" with 12.48 s left,
  "arming the boundary latch in 10.98 s", armed, "latched at ring 78729294 (fill 1536)", "switch 1: ...
  latched at the old track's end; paused; boundary reached 0.016 s", DAC ready 1.408 s, "rewound to
  0.000", switch done 1.591 s; Music then playing it at 96000. The lateArmAt path (a stream's pre-roll
  ~100 s early) was not exercised: needs an Apple Music boundary into hi-res.
- Getting there: AppleScript "play track N of <playlist>" plays that one track and queues nothing;
  "play <playlist>" didn't start the new playlist; no Up Next API. The owner double-clicked in Music. Two
  earlier stops were the CPH track being unchecked (enabled false: Music skips it); the owner re-checked
  the CPH songs. Library "sample rate" for Apple Music items reads 44100 even when the stream is 96k.
- Boundary switch, Apple Music streams (5969a5d, ~13:55): temp playlist "LS bench stream (temp)": Bad
  Religion "O Come, O Come Emmanuel" (44.1k, lossy then lossless) -> Audio Brewers "Fotis' Drums
  Improvisation" (48k lossless). The next stream's decoder came 124 s early: "next track needs 48000 Hz;
  124.23 s left, arming the boundary latch in 0.00 s and again in 122.73 s"; the 5 s arm expired ("no
  boundary within 5 s; disarmed"); at 2652.281 "pre-roll came early; arming the boundary latch again";
  "latched at ring 154720670 (fill 2048)"; "switch 3: ... latched at the old track's end; paused;
  boundary reached 0.415 s"; DAC ready 1.371 s; "rewound to 0.000"; switch done 2.316 s. The lateArmAt
  fix works: before it, this boundary was "not latched: cut at the play position".

# Helper and device menu (1fe6c4a, Xcode build, 2026-09-28 14:09)
- MediaRemoteAdapter helper: 5969a5d's helper (43885) orphaned when it quit; gone after 1fe6c4a
  launched (launch cleanup; its print() isn't in the unified log, so inferred from the pid). On
  1fe6c4a: quit -> helper gone; relaunch -> helper 64787 (parent 64775); kill -9 -> 64787 parent 1;
  relaunch -> 64787 gone, only the new helper (parent 64871).
- Selected Device now lists Default Device, DELL U2723QE, MacBook Pro Speakers, Loopback Audio, Babyface
  Pro; "LosslessSwitcher" is gone.
- Found, not changed: Selected Device isn't restored at launch (saved UID is the Babyface; the menu
  shows Default Device): AppDelegate.handleDevicesMenu, which restored it, is commented out.
- 092b92a / 5f70ba2 (menu + scripting): with the engine on the menu shows Show Icon, Prefer Closest
  Sample Rate Multiple, Renderer Engine ✓, Virtual Output Device, Bit-Perfect Check, About, Scripting,
  Quit (Bit Depth Switching, Detect Local Files, Pause While Switching, Gap After Switching, Selected
  Device hidden). Test script (records its args): 092b92a got the engine's "48000 32" plus three
  "48000" from the regular path (the virtual device's rate); 5f70ba2: one call, "44100 32" ("script:
  ... 44100 32" at engine start). Test script setting cleared afterwards.
- 3853526 (menu names the DAC): engine on "44.1 kHz / Babyface Pro (73020432)" (was "LosslessSwitcher");
  engine off "Babyface Pro (73020432)" (the default again); off with the default on the speakers "48.0
  kHz / MacBook Pro Speakers"; on again "Babyface Pro (73020432)", hogged, DAC ready 0.511 s.

# Control Center and the hogged DAC (2026-09-28 afternoon)
- After a quit, Control Center's Sound menu listed no Babyface, nothing checked, empty slider, crossed-
  out speaker (the owner's screenshot 14:29), while Core Audio had the Babyface alive, not hidden, hog -1,
  canBeDefault 1, the default. `killall ControlCenter` brought it back. Not reproduced in two tries
  after that (start/quit; start, open the menu while hogged, quit): listed and checked each time.
  While hogged the Babyface keeps canBeDefault 1, so Control Center lists it (only its driver decides).
- Tool for next time: research/renderer-engine/tools/control-center-refresh.swift (a public empty
  aggregate for 0.3 s: a device-list change for every process). Run it before killall; if it brings the
  DAC back, the engine can do it on release.
- Fix (next commit): with Default Device, picking the DAC itself as the default output made the engine
  follow it (teardown + setup, a gap). Now it only takes the default back.
- a6f04f3 test (Selected Device = Default Device, engine on, Babyface hogged): setting the default output
  to the Babyface from another process returned noErr, but the default never changed (polled every
  20 ms: "LosslessSwitcher" throughout) and the engine logged nothing. Core Audio silently ignores a
  default change to a device another process hogs. So the Sound menu can't take the DAC over, and the
  new "DAC picked as default" branch is a safeguard that doesn't trigger here. Hypothesis (untested):
  Control Center believes its request worked, which could be how its list went stale; test by clicking
  the Babyface in the Sound menu while hogged, then quitting. Selection restored to the Babyface.
- Control Center test (a6f04f3, 14:42): engine on, Babyface hogged (pid 76994); the owner clicked "Babyface
  Pro" in the Sound menu: Control Center showed a beach ball (process sleeping, then 37% CPU); the
  default never changed ("LosslessSwitcher" throughout, polled every 20 ms); the engine played on (0
  under); other processes' HAL queries answered at once. Quit at 14:43:11: default -> Babyface at 1.67 s
  (the engine's restore), Control Center idle again; the owner: beach ball gone, Babyface listed and checked.
  So picking a hogged DAC in the Sound menu hangs Control Center until the hog goes (whether it had
  ended before the quit is not known); the stale list itself did not recur. Known issue: while the
  engine runs, don't pick the DAC in the Sound menu. The app can't remove it there (its driver decides).

# Idle step-aside (43358a0, 2026-09-28 15:12, RendererIdleSeconds 10 for the test)
- Music paused: "Music idle 10 s: stepping aside" at 36.094; hog released, default restored to the
  Babyface (held 3 s), detached; the Babyface hog -1 and the default, the virtual device not
  default-eligible, the menu names "Babyface Pro (73020432)".
- Play pressed at 39.527: "playback began while stepped aside ... taking the output back"; Music paused
  40.389; default -> virtual device, hogged 40.617, DAC ready 41.474; "switch 1: ... restarts at 44100 Hz
  (no rate change)"; "rewound to 100.532 (was 101.120, played ~0.488 s)"; playing again 41.734 (about
  2.2 s from the press). The rewind is the half second Music played to the DAC directly, not ~1.5 s
  more (switchRate now measures to the pause).
- Paused at 47.371, stepped aside again at 57.375. Volume keys during play: -56 / -52 dB. One
  "NSRunningApplication lists no Music, but pid ... is alive" (no false quit).
- RendererIdleSeconds removed afterwards (60 s).

# TPDF dither option (2026-09-28, desk only, not benched)
- Why: with Overshoot Protection on, OutFormat.write applied the -3 dB in float and rounded straight to
  the DAC's integer depth: undithered requantization (at 16-bit, correlated distortion at ~-98 dBFS;
  at 24-bit ~-144 dBFS, under any DAC's analog floor). Found in review, not heard on the bench.
- What: Advanced > TPDF Dither, off by default (defaults key TPDFDither), enabled only when B writes an
  integer format under 32 bits (TPDFDither.dacBits, published from updateOutFormat). A buffer is
  dithered only if a sample can't be written exactly (gain on, or more source bits than the DAC), so
  bit-perfect output and digital silence are untouched. Noise: difference of two xorshift32 uniforms,
  ±1 LSB triangular, state kept on B's IO thread. Exclusive Mode only; the tap engine writes float.
- Desk check (dither_test.swift, a copy of the noise and quantize code): noise variance 0.1665 (TPDF
  1/6), triangular histogram; 16-bit-exact input with dither on comes out bit-identical, silence stays
  zero; a constant 0.3 LSB input averages 0.000 LSB undithered vs 0.300 dithered; a -90 dBFS 1 kHz sine
  with the -3 dB gain to 16-bit: undithered fundamental 0.958 LSB (should be 0.733) with H3/H5 at
  -12 dBc, dithered 0.733 LSB with H3/H5 at the noise floor (-50/-45 dBc in a 1 Hz bin).
- Bench: BENCH-BRIEF item 11.

# Bench: 2d26947 on Executor (M5 Pro, MT 48), 2026-09-28 evening
Build: research/typecheck/make_xcode_dev_app.sh from a detached worktree at origin/renderer-vdevice
2d26947 (MediaRemoteAdapter resolved to dizzysound/mediaremote-adapter lossless-switcher 2e59752).
Replaced the 19:15 Dev build in /Applications; LSOutput.driver kept (1.1.2, installed 07:04; same
source, a different binary build, not reinstalled). Scripted items only (1, 4, 5 by log, 7, 8, 9, 10
by log, 11 label, 13); no listening checks. Raw logs, stdout and the probe/driver scripts:
data/2026-09-28-executor-2d26947/ (engine t=0 is about 20:23:00.8 in run 1).
- 1, DAC: MT 48 offers int32 non-mixable (flags 76); "hog DAC: 0, hogged", B writes int32. Ready
  after 12.008 s (NOT ready) on the first launch, with stdout "[TrackBoundary] device keeps stopping
  (19 starts); restarting silent output" and 7 "clock: phase jumped ~47999 frames" re-locks in the next
  8 s (0.5 s of frames at 96k, one per PLL tick); steady from 21 s (under 0 over 0). Not reproduced:
  later starts 3.670 s and 2.049 s, no phase jumps. Switches 1.8-2.5 s.
- 2 (by log only): "volume: DAC has no settable output volume; the volume keys change nothing".
- 4: "Selected Device changed to MacBook Pro Speakers; following it", and back to MT 48. The virtual
  device isn't in the list. The follow keeps the new DAC's current rate (setUpDAC: applyRate(CA.nominal
  (d))): Earth then played at 96k on the speakers (menu "96.0 kHz", Bit-Perfect Check silent about it)
  until a later switch. The follow back found the MT 48 at 44.1k from before and used that.
- 5: speakers float32 mixable, "clock: ring at 0 frames before the lock (target 2048); refilling
  first", then lock at fill 2048. under 22528 once (the refill), flat for the next 60 s. Volume
  forwarded to element 0 (-21.5 dB). The virtual device's own volume went +6.0 dB -> -51.0 dB then
  and stayed there after the follow back (audio at unity per the log; noted, not changed back).
- 7: kill -9 -> default left the virtual device after 4.13 s, to MacBook Pro Speakers (not the MT 48
  the engine had restored from); the helper outlived the app. Relaunch: "at launch: recovering the
  output after an unclean exit: DAC MT 48, mixable 0, default output (was MacBook Pro Speakers) 0" and
  "[MediaRemoteController] stopped an orphaned MediaRemoteAdapter helper, pid 98408: 0".
- 8: quit -> "default output restored to MacBook Pro Speakers" (the default recorded at the recovery
  launch), MT 48 un-hogged, mixable, no run.pl left, no restart message.
- 9 (RendererIdleSeconds 10): "Music idle 10 s: stepping aside", MT 48 un-hogged and default. Play:
  "playback began while stepped aside (Earth); taking the output back", "rewound to 196.711 (was
  196.945, played ~0.134 s)". Press to rewind logged 4.36 s, but that included switch 4 (below).
- 10: "inter-sample overshoot protection on: output -3.0 dB, not bit-perfect" / "off: output
  unchanged". Level not measured.
- 11: menu reads "TPDF Dither (not needed: DAC takes 32-bit)".
- 13: helper killed at 97 s: new helper after 1.16 s; then three kills 3-5 s apart: 1.15, 1.10, 2.17 s;
  stdout "restarting in 1 s" x3 then "in 2 s". App CPU 0.0-0.3 %. Rate switches after the restarts
  still worked (96k -> 48k, 48k -> 44.1k).

## Found: a skipped-to track takes the previous track's decoder line
Reproduced twice in one run (AppleScript "next track" on a shuffled Apple Music station, ~12 s apart),
confirmed against Music's own log (data/.../music-decoder-skips.txt) and Music's "sample rate" of the
current track (Earth: 48000).
- Deadbeat Drag: Playing at 173.833 (20:25:54.59); engine "decoder 48000.0 Hz (seen 10.259 s before
  Playing)", which is Ticking's line from its own rewind at 163.574. Music logged Deadbeat Drag's
  decoder, 44100 Hz, at 20:25:54.979, 0.39 s after Playing. No switch: it played at 48k.
- Earth: Playing at 186.027; engine took that 44100 line ("seen 11.737 s before Playing") -> switch 3
  to 44100. Music's line for Earth, 48000 Hz, came at 20:26:07.21, 0.42 s after Playing. Earth ran
  at 44.1k for ~3.5 min until the step-aside resume re-decided "switch 4: Earth needs 48000 Hz".
- Cause (traced, VirtualDeviceEngine playerInfo handler): a new track takes decoderRates.last(where:
  date > lastNewTrackAt). The previous track's own line can come after its Playing (a skip: ~0.4 s;
  a switch's rewind re-creates the decoder just after Playing), so it passes that test and is taken
  for the next track. Natural transitions weren't tested; the early pre-roll line there may mask it.
- Possible fix direction (not written): drop lines logged within ~1 s after the previous track's
  Playing when a later line exists, or, on a Playing that follows a skip, wait for a line newer than
  the notification (the existing 3 s "awaiting" path).

# Fixes from the Executor bench (2026-09-28, desk-checked; bench pending)
- 6b4915c, skip decoder line: decoder lines up to 2 s after a track's Playing, or 1 s after a
  switch's play, are that track's own (ownLinesUntil). A new track whose newest line falls in the
  previous track's window waits up to 1 s for a newer line and takes the old one only if none comes
  ("may be the previous track's; waiting 1 s for its own" / "no newer decoder line ... the earlier one
  decides"). Replayed against the logged run: Deadbeat Drag and Earth would each wait and get their own
  line (44.1k at +0.39 s, 48k at +0.42 s); Ticking (skipped to during switch 2) waits 1 s and falls back
  to its 48k line, as before. Natural transitions: the pre-roll line comes 8-12 s (streams up to
  ~105 s) early, outside the window, so they decide at once. Resume from step-aside now uses the rate
  decided for the same track (trackRate), not the newest line (Earth resumed on the next track's 48k
  pre-roll line: right by luck).
- 277d43f, virtual device volume: plug-in 1.1.2 kept NullAudio's -96..+6 dB squared taper, so unity
  read +6 dB and the engine's slider read wrong (0.6641, the DAC's -21.5 dB, read -51.02 dB; the
  Executor probe saw -51.0). The control never applied gain (gVolume_Output_Master_Value is read only
  by the property getters), but the readout suggested a boost or a cut. Plug-in 1.1.3 (build 5): 0 to
  -64 dB, linear in dB, same as the engine; harness: 7 volume checks pass on 1.1.3, 4 fail on the
  installed 1.1.2. Engine: RendererVolumeTopDB/RendererVolumeRangeDB removed (the window must match
  the plug-in); a DAC without volume (MT 48) holds the virtual device at 0 dB, unmuted; stop leaves
  it at 0 dB. Needs the plug-in update (menu, admin password).

# Bench: coffee (MacBook Air M2, macOS 27.0, AudioQuest DragonFly Black v1.5), 2026-09-28 night
First Exclusive Mode run on this Mac: plug-in 1.1.3 installed from the menu (owner's password).
Data: data/2026-09-28-coffee-5d75e9a/ (run 1 = 5d75e9a, run 2 = 2fd8f41).
- DAC: int24 non-mixable (flags 76), hogged, ready after 0.506-0.512 s; 48k -> 44.1k switch 1.285 s.
- Run 1 (5d75e9a), resume from the idle step-aside: 13 of 13 take-backs failed. start B blocked
  ~7.3 s and returned 35, "setup failed; staying stepped aside", then scripts.play() -> Music played to
  the DAC directly -> "playback began while stepped aside" -> another take-back, every ~11 s. Pausing
  Music didn't stop it (the failure path plays). Stopped with SIGTERM; DragonFly restored by hand
  (data/2026-09-28-executor-2d26947/mixable.swift, setdefault.swift). The first start at launch
  (Music not playing) was fine: start B 0.24 s.
- 2fd8f41: (a) setUpDAC waits up to 2 s for kAudioDevicePropertyDeviceIsRunningSomewhere to clear;
  (b) a failed take-back ignores Playing for 30 s; (c) volume in dB without a dB -> scalar conversion.
  - (a) Three take-backs passed ("DAC was still running for another client; stopped after 0.043-0.046
    s", start B 0, ready 0.511 s, rewound ~0.2 s before the pause). Then one FAILED again at 44.1k
    with the DAC NOT running somewhere at hog time (no wait line): start B 35 after 7.35 s. So the
    wind-down wait is not the cause, or not the whole of it. OPEN.
    Differences to chase: the failure came 0.10 s after Music's Paused (the passes: DAC still busy,
    ~45 ms wait); rate 44.1k vs 48k; the take-back overlapped a "new track ... holding at the gate"
    (Urban Disco, a local AAC file, whose Playing arrived 1 s after the first). Next: log
    DeviceIsRunning / IsAlive / hog owner right before AudioDeviceStart, time AudioDeviceStart itself,
    and try stop+start B once on a 35 before giving up (the switch path's "keeps stopping" restart).
    Is 35 AudioDeviceStart's own status or a stalled start timing out in coreaudiod?
  - (b) Worked: one failure, then "no take-back for 30 s", Music played on, no loop.
  - (c) Worked: "set in dB (no dB -> scalar on the DAC)"; slider 0.25 -> DAC -48.0 dB, virtual device
    reads -48.0 dB (5d75e9a read 0.0 dB against a DAC at -16/-36 dB: DragonFly has a -64..0 dB range
    and a dB value but kAudioDevicePropertyVolumeDecibelsToScalar returns 'who?').
- Item 14 (skips) not exercised: the queue was a library playlist (local AAC, 44.1k); two of three
  "next track"s left Music paused (the owner was also at the Mac). The first skip took its own 44.1k
  line (0.172 s before Playing) and switched correctly.
- Owner lowered the DragonFly with the keys while stepped aside: -16 -> -48 dB (not the engine).

## Found: start B's 35 is a HAL-client IO context left paused at the step-aside (2026-09-28 night)
From the coffee Mac's unified log (data/2026-09-28-coffee-5d75e9a/run*-halclient-io.log, run2-failure-*,
run1-stepaside-*; engine t=0 = 20:54:05.03 in run 2).
- The failed start never reaches coreaudiod: no StartIO on the DragonFly. Our own process logs
  "HALB_IOThread::_Start: IO is still disabled after waiting" 2.1 s after AudioDeviceStart, then
  "HALC_ProxyIOContext::_StartIO(): Start failed - StartAndWaitForState returned error 35" (35 = EAGAIN)
  at 7.4 s. Music never ran IO on the DAC in that take-back (a cloud track still loading; its AUHAL
  says "not already running" when it moves to the virtual device), so the in-flight-client theory is out.
- The HAL client keeps one IO context per device per process (id 610 in run 1, 1584 in run 2), across
  AudioDeviceDestroyIOProcID/Create. Its pause count must be 0 for IO to start. A DAC config change
  (our mixable/non-mixable physical format set) makes coreaudiod send PauseIO/ResumeIO, which our
  process handles on several threads at once.
- At a bad step-aside the pair arrives out of order: run 1, 20:48:42.649-.652: pause -> 1, pause -> 2,
  resume -> 1, resume -> 0, resume "<- 0 0 0" (clamped at 0: one decrement lost), pause -> 1. Nothing
  undoes the last pause; every later start on that DAC in the process waits and fails. Run 1: stuck at
  the first step-aside, then 12 of 12 logged take-backs "IO is still disabled" with the count at 1.
  Run 2: the step-aside at 20:56:06.55 left 1584 at 1 (the earlier ones ended at 0); the next take-back
  failed. A new process gets a new context, which is why the first start at launch always works.
- So 2fd8f41's wind-down wait and the timing near Music's Paused are incidental. Stop+start B again in
  the same process can't help (the count only moves by pause/resume pairs, which net zero).
- Reproduced without the app: research/renderer-engine/tools/stuckstart.swift cycles the DragonFly
  the way take-back and step-aside do (hog, non-mixable, IOProc start 0.4 s, stop, destroy, mixable,
  hog released; silence out). Coffee, 21:04: start 35 after 7.5 s at cycle 5; stop+start: 35 again
  after 7.5 s; cycle 6 (after a full teardown and 0.6 s): 35 again. Its unified log shows the same
  clamp ("R1 R0 R0 P1": a resume at 0, then the count never goes below 1). Each cycle produces ~60
  pause/resume notifications on our context, not one or two.
- Recovery in the same process, tried and failed: stop+start the IOProc; tear down and set up again
  (cycle 6 above; run 1's take-backs minutes apart); AudioHardwareUnload() then a new IOProc (35
  after 7.5 s, three cycles in a row). A fresh process always starts (the next harness run, and the
  app's first start at launch).
- The trigger is intermittent: 2 of ~12 harness processes, both at cycle 5, both within seconds of
  Music having played (paused 1 s before the run). 25-cycle runs and seeded 8-cycle batches mostly
  pass; hog only (no format changes) 32/32 and 500 ms gaps between the changes 32/32 passed, but so
  did an interleaved control with no changes (32/32), so those zeros say nothing yet.
- Coffee restored afterwards: DragonFly default, int24 mixable, hog -1, -48.0 dB, Music playing, no
  RendererIdleSeconds.
Next (the owner's call): the only recovery shown to work is a new process. Options: (a) on a 35 at
take-back, relaunch the app (the launch path already recovers the output; Music is paused and
resumed by setUp); (b) probe for the stuck context at the step-aside (a short silent start while
Music is paused) and relaunch then, so the listener never waits the 7.5 s; (c) run IOProc B in a
helper process that is restarted per take-back. Avoidance (fewer or spaced DAC config changes) needs
a reliable repro before it can be judged.

# Bench: 893638b on coffee (DragonFly Black), 2026-09-28 21:25 to 2026-09-29 04:53
Data: data/2026-09-29-coffee-893638b/coffee-overnight-engine.log (RendererIdleSeconds 10).
- Step-aside probe: 7 step-asides, each "DAC probe: start 0 after 0.07-0.08 s"; 7 take-backs, each
  start B 0, DAC ready ~0.5 s, rewound ~0.17 s before the pause. The probe doesn't disturb the
  normal path. The stuck context didn't recur, so the 35 -> relaunch path is UNTESTED on the bench.
- NEW, separate: after switch 9 (48k -> 44.1k, t=1282, ~21:46) the clock never locked for ~5.8 h
  ("clock: DAC scalar 0.998949 not settled; waiting to lock"; locked briefly at t=21055 and 21990,
  lost again within ~5 min each time). The ring sat at 0-512 frames (target 2048) and underruns grew
  ~512 frames per 30 s all night (18432 at t=1288 -> 442880 at t=26884): likely an ~12 ms dropout
  about every 30 s while Music played. Not investigated beyond the log; the measured DAC scalar
  (~0.99895) is ~1000 ppm from 1 and "not settled" keeps the steering off.
- Restored: app quit cleanly (default DragonFly, int24 mixable, hog -1, -48.0 dB); RendererIdleSeconds
  and RendererLastRelaunch deleted. Music came back paused after the quit although it was playing
  (tearDown's resumeMusic) and was restarted by hand.

# Export Logs and the relaunch test (f065355 .. 216e89f, coffee, 2026-09-29 morning)
- Relaunch path, forced with the one-shot RendererProbeForceStuck: step-aside -> "DAC probe: ... acting
  as if it were 35" -> relaunch -> old engine "engine stopped" (clean quit) -> new process 14 s later,
  no Microphone prompt (same binary), "at launch: relaunched after a step-aside ..." pointing at
  .1.log; the hook cleared itself. The relaunched process stepped aside (probe start 0) and took the
  output back (start B 0, ready 0.5 s, rewound 0.17 s before the pause).
- Engine log: keeps the two runs before it (.1, .2); the first line has the wall clock, version,
  commit (LSGitCommit, from make_xcode_dev_app.sh, "-dirty" for uncommitted builds), macOS, Mac model;
  the 30 s status line has the wall clock, the clock-lock state and the DAC's HAL scalar.
- About > Export Logs… and AppleScript `export logs to "<path>"` (for SSH benches: on the coffee Air
  the menu-bar icon goes under the notch while the orange microphone indicator shows). The zip: engine
  logs; audio-devices.txt (every device: default flags, rates, hog owner, running/somewhere, stream
  physical/virtual/available formats with non-mixable flags, volume in scalar and dB with range, mute,
  latency, safety offset, buffer); settings.txt (app defaults, Music's AutoMix/Sound Check/Lossless
  prefs, Music state and current track, installed and bundled plug-in versions, HAL plug-ins);
  system.txt (processes, sleep/wake events); unified-log extracts for 4 h: hal-client (this process's
  IO context pause/resume/start/"IO is still disabled"), coreaudiod (config changes, starts, stops,
  hog, overloads, default device, errors), Music (decoder formats, output selection, play commands),
  audio-errors (errors and faults from coreaudiod, kernel and the audio subsystems); crash reports of
  the app or coreaudiod from 14 days. On coffee: 2 min 22 s, ~0.7 MB. A kernel "usbaudio" query was
  empty there and was replaced; pmset's log on coffee has no Sleep/Wake events at all (80k Assertions).
- Coffee afterwards: 216e89f running, bench defaults cleared, Music playing. Left for the owner: two
  export zips on the Desktop, and an older copy at ~/lsbench/new/LosslessSwitcher Dev.app (2fd8f41,
  same build number, shows as a second "LosslessSwitcher Dev" in Spotlight).
- The orange microphone indicator and Control Center's Mic Mode (noise reduction) offer come from the
  engine reading the virtual device's loopback input; avoiding them would need another way to get the
  samples out of the plug-in (not planned).

# Reproduced: no clock lock at 44.1k on the DragonFly (216e89f, coffee, 2026-09-29 05:27-05:45)
Data: data/2026-09-29-coffee-216e89f/ (repro-44k-engine.log, clockrate.txt); tool: tools/clockrate.swift.
- Repro in < 3 min, no idle tricks: Music played 44.1k -> 48k (Intruder) -> 44.1k (St. Stephen).
  From then on every status line: "clock waiting (DAC scalar not settled)"; DAC HAL scalar 0.99886 ->
  0.99958 within ~1.5 min; virtual device scalar left at 1.000000000; ring 0-512 (target 2048);
  underruns +512 frames per 30 s = 17 frames/s = ~390 ppm, matching the DAC scalar's ~420 ppm.
- The overnight run: both brief locks (t=21055, 21990) were during 48k tracks and ended only because
  the next track switched to 44.1k (the switch resets the lock); while locked at 48k, underruns stayed
  flat (350208 for 4 min) and the virtual scalar settled at 0.9999956. Every 44.1k stretch never
  locked. So: 48k locks within ~1 min; 44.1k never does.
- clockrate (engine quit, DAC mixable, not hogged, 60 s each): 44.1k +1135 ppm flat for 60 s, twice;
  48k +1045 ppm falling (cumulative mean +642 ppm at 60 s, so the recent rate near 0). NOT an
  independent measurement: it uses the HAL's own sample/host timestamps (it mirrors mRateScalar
  exactly). What it shows is the HAL's timestamp model for this DAC: ~1100 ppm off after every
  (re)start, converging within ~1 min at 48k, slowly and to ~400 ppm at 44.1k. The ring's underrun
  drift (the engine's frames consumed vs produced) is the independent signal, and it agrees (~390 ppm).
- Owner: the DragonFly uses a licensed, unusual USB audio implementation (asynchronous, its own
  clocking); a real ~400 ppm offset in the 44.1k family is plausible, as is the slow convergence.
- Cause in the engine: pll() won't lock while abs(rB - 1) > 100e-6 ("not settled"), and meanwhile the
  virtual device keeps its last scalar (1.0 after a switch), so it runs ~400 ppm slow against this DAC
  and the ring drains: a ~12 ms dropout about every 30 s for as long as 44.1k plays. The gate assumes
  a real clock is within 100 ppm of nominal; the DragonFly at 44.1k isn't. Fix direction (not done):
  gate on the scalar being steady (its change over a few seconds), not near 1; while waiting, follow
  the DAC's scalar rather than holding 1.0. Check the MT 48 / Babyface logs don't regress.
- Coffee afterwards: app relaunched (216e89f, no prompt), hogged, Music playing; DAC -48 dB.

# Fix: clock lock gated on a steady DAC scalar, following it while waiting (13c74f8, 2026-09-29)
- Change (pll()): the lock waits until the DAC's HAL scalar is steady, not near 1: the means of the
  older and newer halves of the last 4 s (pll ticks every 0.5 s) within 20 ppm; seeded on the newer
  mean. Until then the virtual device's scalar is set to the DAC's latest scalar each tick (was: held,
  1.0 after a switch), so the ring doesn't drain. After 30 s of waiting it locks on the 4 s mean anyway
  (logged). The +-300 ppm P+I around dacScalarEst is unchanged. New log lines: "not steady yet;
  following it until the lock", "steady at X after Y s", status "waiting (DAC scalar not steady,
  following it)".
- Why following is right: on the DragonFly the ring's drain tracked the HAL scalar, not nominal: in
  repro-44k-engine.log the scalar sat at 0.998864 (-1136 ppm) for the first minute and the ring lost
  ~1500 then ~1160 ppm; after it moved to ~0.99958 the loss was ~390 ppm. So the DAC consumes at the
  rate the HAL scalar says, including the ~1100 ppm start-up offset.
- Replay (tools/gatesim.py, over the music-tap-spike vdev clock.csv recordings: MT 48 16 ch r1-r7,
  m1-m4, s1-s2, and the 2 ch runs a1, h1-h2, v1, s3): the gate first passes 3.3-5 s after the old lock
  point (so each lock comes ~3-4 s later than before, while following); once settled it never failed
  (worst half-mean difference 19 ppm, MT 48 at 192k, sd 7.7 ppm). s2 (88.2k, first scalar 1.001148,
  the -285 frame walk): passes at +5.1 s, when the scalar is back within a few ppm of 1.0, so the
  post-switch protection holds. Babyface recordings: none with clock.csv found; not replayed.
- MT 48 instability (the owner asked): the first-launch "phase jumped ~47999 frames" re-locks on
  Executor come from the DAC restarting ("device keeps stopping (19 starts)"), not from this gate;
  the MT 48 at 44.1k waited 2 s on the old gate (0.999050) and then locked. Not expected to change.

# Bench: 13c74f8 on coffee (DragonFly Black), 2026-09-29 06:00-06:27
Data: data/2026-09-29-coffee-13c74f8/coffee-13c74f8-engine.log. PASS: 53 status lines (~26 min), every
one "under 0", clock locked throughout.
- 44.1k from launch: "not steady yet; following it" at 46.8, "steady at 0.998861 after 3.5 s", lock
  at fill 1536. Then the scalar moved 0.99886 -> ~0.99958 within ~1 min and wandered 0.99957-0.99971;
  the lock tracked it (virtual scalar within ~100 ppm of the DAC's), fill 1024-1536, 11 min.
- 48k (Biko (Live), switch 1.5 s): steady at 0.998960 after 4.6 s; the scalar went to ~1.00000 within
  ~1 min; correction peaked ~+120 ppm; under 0.
- Back to 44.1k (the case that never locked before; "Everything" on shuffle, switch 1.36 s): steady at
  0.998867 after 3.6 s; the same ~700 ppm move at +1 min, correction peaked +226 ppm (0.999779 vs
  0.999553): the closest to the +-300 ppm clamp seen. 11 min, under 0.
- A library "Intruder" (Peter Gabriel) is 44.1k lossy; the 48k one in the repro was another version.

# Bench: 13c74f8 on the pastor Mac (MacBook Pro 18,3, macOS 27.0, Babyface Pro), 2026-09-29 06:23-06:59
Data: data/2026-09-29-pastor-13c74f8/ (engine log; the run before the plug-in update). PASS.
Replaced build 24 (no commit stamp; kept at ~/lsbench/old-build24); the owner answered Microphone and
updated the plug-in 1.1.2 -> 1.1.3 from the menu over Remote Desktop (the engine stopped and restarted
cleanly for it). Music AppleScript over SSH timed out until then.
- 44.1k at start: "not steady yet" at 2.2, "steady at 1.000005 after 3.5 s", lock at fill 2048. One
  underrun of 512 frames before the first status line (31.7 s), none after (5 min flat). Not traced:
  Music started 0.08 s after B was ready (the engine restarted with Music playing); following at
  1.000005 for 3.5 s is < 1 frame of drift, so not the wait. It did not recur at the later switches.
- 96k (Oh, Blest Is He That Came, switch 1.3 s): steady at 1.000005 after 3.5 s; 3 min, no new
  underruns. Then Music stopped (single-track play), idle step-aside ("under 5120" counted at the
  teardown, fill 0, clock stepped aside).
- Back to 44.1k (The Right Rite, switch 1.34 s): steady at 1.000005 after 3.6 s; 10.5 min locked, underruns
  flat (5120, all from the step-aside teardown), fill 1536-2048. Afterwards Music paused (as found).
- Babyface scalar: 1.000003-1.000008 throughout; the gate adds ~3.5 s before each lock (the old one
  locked at once), with no cost seen.

## Found: a take-back to a different track uses the old rate (resumeFromIdle), pastor Mac 06:35
- After the step-aside, `play` of Badlands (44.1k) while stepped aside: "playback began while stepped
  aside (Badlands); taking the output back", setUp at 96k, then "switch 2: Badlands restarts at 96000
  Hz (no rate change)". Music's decoder line for Badlands came at 620.619, ~1.1 s after its Playing
  (619.489) and after resumeFromIdle had chosen the rate (switch 2 logged at 620.627, after the pause).
  Music confirmed Badlands 44100. It played at 96k (resampled by Music, not bit-perfect) until the
  next track.
- Cause (traced, not reproduced twice): for a track other than lastTrackID, resumeFromIdle takes
  decoderRates.last if < 30 s old (the last line was the hymn's 96k, 208 s old: nil), else
  LocalTrack.currentStats, else curRate. It doesn't wait for the track's own line the way the
  new-track path does (up to 3 s). Which of LocalTrack or curRate gave 96k isn't in the log.
- Fix direction (not done): when the resumed track isn't lastTrackID, wait up to ~2 s for a decoder
  line newer than its Playing (pumping), then fall back as now; log which source decided.
- Also seen: "Born to Run" by database ID 82644 (96k) played a 44.1k entry of the same name (Music's
  play resolved another track; Music's own log: 44.1k ALAC). The engine was right.

# Fix: take-back to another track (ccbaf2a, 94cee07), pastor Mac Babyface, 2026-09-29 06:56-07:05
Data: data/2026-09-29-pastor-takeback/ (ccbaf2a-engine.log, 94cee07-engine.log); repro: tools/takeback.sh
(RendererIdleSeconds 10: hymn 96k, pause, step-aside, play Badlands 44.1k; x3).
- ccbaf2a: resumeFromIdle, for a track other than lastTrackID, takes a decoder line from 2 s before its
  Playing on, waiting up to 2 s for one; else its file header; else the newest line; logs "resume: X at
  N Hz (its decoder line | file header | ...)". Right in two runs where Music's line came before
  Playing (hymn 96k, the 2014-08-20 talk 44.1k).
- The Badlands repro then showed a second, older race: Music's pause took > 1 s, its late "Playing
  Badlands" came after resumeFromIdle's 1 s wait with inRoutine already cleared, was taken as a new
  track, and switched before setUp (switch 4: "boundary NOT reached", "DAC NOT ready after 12.038 s",
  done after 14.3 s, then a second restart, switch 5). Not caused by ccbaf2a (its code runs after
  setUp; no "resume:" line was logged), but the same path.
- 94cee07: inRoutine stays set from the take-back's pause through setUp and the rate decision (Music's
  notices there echo our own pause); switchRate pauses, rewinds and plays anyway.
- 94cee07 bench: Badlands after the hymn 3 of 3 right ("resume: Badlands at 44100 Hz (its decoder
  line)", once after the 2 s wait: "decoder line after 0.01 s"), switch 1.32-1.33 s, no stray new-track
  switch, clock lock ~4 s later. Same-track resume (hymn paused, stepped aside, play): "restarts at
  96000 Hz (no rate change)", rewound to 9.234 (paused at ~9.6), unchanged. No Microphone prompt for
  94cee07 (the ccbaf2a answer carried over).
- Pastor Mac afterwards: 94cee07 running, Music paused (as found), RendererIdleSeconds deleted.

## Found: Exclusive Mode off on coffee left Music silent (13c74f8, 2026-09-29 07:06)
The owner turned Exclusive Mode off while Music played (Ulaid, 44.1k) and heard nothing.
- Engine: tearDown paused Music (Music: "pause command (ae_Pause)" 07:06:03.688), DAC mixable, hog
  released, "default output restored to AudioQuest DragonFly Black v1.5", held 3 s, "engine stopped";
  then its resume: Music "play command" 07:06:07.925, "paused -> playing".
- Music re-routed to the DragonFly at 07:06:05.04 (routeChangeNotification, outputs = DragonFly) while
  paused.
- coreaudiod: StopIO x3 at 07:06:04.69-.98, then NO StartIO on any device through 07:12, although Music
  reported playing (07:06:07.9; stalled at 07:06:22), and later plays (owner 07:06:27 back, 07:06:49
  play; ours 07:08:49). StartIO is logged normally (the engine's 06:00:27 start is there). So Music's
  playback pipeline stopped producing IO after the device change; the output switch itself worked.
  Traced, not reproduced; cause inside Music not known. Related: the overnight run's "Music came back
  paused after the quit although it was playing".
- DragonFly volume: 0 dB is the owner's setting (DAC at unity, level set on a preamp). I misread it as
  a change, set it to -48 dB at 07:08, and put it back to 0 dB at ~07:10. The -48 dB in the earlier
  coffee entries is what the owner had then, not a standing setting; don't restore it.
- Follow-up (07:12-07:16): not reproduced. Coffee's Music (same process since the night, pid 1908) was
  still stuck at 07:14: "play" -> "playing" at position 0.0 and the DragonFly not running (checked with
  kAudioDevicePropertyDeviceIsRunningSomewhere). Quitting and reopening Music fixed it (DragonFly
  running, position advancing). Then Exclusive Mode on -> off by the owner (07:15:31-07:16:01), same
  teardown sequence as 07:06: the owner heard it continue; DragonFly running, position 61 -> 65 s.
  Pastor Mac, the same toggle (07:12:48-53): Babyface running, position advancing (no one listening;
  its RME driver logs no HALS_IOEngine2 StartIO, so the coreaudiod StartIO check doesn't apply there).
  So the stuck state is inside that Music session (it had played through the whole night's builds,
  relaunches, switches and take-backs), not a fixed result of the toggle. Open: what puts Music
  there. If it recurs: check DeviceIsRunningSomewhere on the DAC and Music's player position before
  restarting Music; tools/running.swift (device running/hog/default).

# Does macOS dither after a digital volume change? (source reading, 2026-09-29)
Question from the owner. Not measured: the Babyface can't answer it (RME's own HAL driver does its
conversion, and its 32-bit integer stream holds every float32 value exactly, so nothing is rounded),
and the DragonFly (Apple's USB class driver, int24) has only analog outputs.
- Apple's published source (github.com/apple-oss-distributions): IOAudioFamily-740.1 (2026-04) and
  AppleOnboardAudio-258.3.1 (2009) contain no "dither" at all. IOAudioFamily leaves float -> integer to
  each driver's clipOutputSamples(). AppleOnboardAudio's AppleDBDMAClip.c (Float32ToNativeInt16/24/32)
  scales to 32 bits, adds a fixed half-LSB rounding constant (32768 for 16-bit, 128 for 24-bit) and
  keeps the high bits: plain rounding, no dither. PowerPC-era code (__fctiw).
- AppleUSBAudio (the DragonFly's driver) isn't in that mirror; today's USB path (DriverKit/HAL) isn't
  published. So: no evidence of dither anywhere in Apple's published output path; the modern USB path
  is unverified. Music's volume and Sound Check are float32 gains before that conversion.
- Consequence: on a 24-bit DAC the undithered rounding sits near -144 dBFS (below any DAC's noise); on
  a 16-bit DAC near -96 dBFS, where TPDF dither is worth having. Deciding test, if wanted: the
  DragonFly's analog out into the Babyface's input, a quiet tone at Music volume 90.

## Not ours: a stream that failed to load stopped a playlist (coffee, 11bd0c6, 2026-09-29 08:03)
Owner: "went from lossy to lossless and the playback stopped; bit depth ? bit". Music's own log: after a
skipNext, the stream for "Here Come The Bastards - Bassnectar Mix" never became ready
(FailedToBecomeReadyForPlayback, CoreMediaErrorDomain -12785; MPCEnginePlayerError 16 "Player item
failed"), and Music paused itself ("UserEvent.pause ... reason: error", PlaybackStopForError); again when
skipped back to (08:03:28). No ae_Pause (ours sends that), no rate switch (all 44.1k); the engine only
saw Playing then Paused, and "no decoder line ... within 3 s", hence "? bit" (correct: nothing decoded).
The owner then played the same track with Exclusive Mode off and on: fine both ways (engine: decoder
44100 Hz lossless). -12785 in Music's log this morning: this track only, plus one near 05:00. Tell for
next time: Music's "reason: error" pause and -12785, not our ae_Pause.

## Found: left channel distorted after taking a DAC Music still streamed to (coffee, 11bd0c6, 08:13-08:21)
- 08:13:59 take-back after the idle step-aside (Music paused at 08:12, stepped aside 08:13:37, play
  at 08:13:59): "DAC was still running for another client; STILL running after 2.005 s", then hog and
  int24 non-mixable anyway, "B writes int24 in 3 bytes". The owner: left channel distorted; still so
  after pause/play; still so after Exclusive Mode off -> on at 08:17:13, which logged the same
  "STILL running after 2.002 s"; clean with Exclusive Mode off. DAC formats read back correct (phys and
  virt int24 flags 76, 6 bytes/frame, hog = our pid), so the mismatch isn't in the settings.
- The other client: the audio process list (kAudioHardwarePropertyProcessObjectList, tools/clients.swift)
  shows only Music (pid 48342, the copy started at 07:14) and us; so it was Music's own stream,
  running > 2 s after our pause. Earlier take-backs today found it stopped within ~0.05 s.
- Mechanism not traced (what the HAL does with a second client's stream on a hogged, non-mixable DAC,
  and why only the left channel). Traced: the collision in both distorted setups, none in the clean one.
- 2bdc720 (with b645054): if the DAC is still running after 2 s, pause Music again and wait up to 3 s;
  still running -> setup fails, the DAC isn't taken ("not taking the DAC while another client plays to
  it"): take-back stays stepped aside (Music plays to the DAC directly, retried later); at start the
  engine idles until Exclusive Mode is turned off (visible only in the log; a menu note would help).
- 2bdc720 on coffee, Exclusive Mode on at 08:20:48 with Music playing: no collision this time (DAC free
  at setup), hogged, locked in 3.5 s; Music -> virtual device only, our app alone on the DragonFly;
  the owner: clean. The refusal path itself is UNTESTED (needs the collision to recur).

# Music only (DESIGN-music-only.md): plug-in 1.1.4, 2026-09-29
- Hook choice: ProcessOutput, not MixOutput. AudioServerPlugIn.h: ProcessOutput processes one client's
  output in the canonical format, in place, before the mix; MixOutput would make the plug-in do the
  whole mix ("no further output operations"). Evidence that coreaudiod calls ProcessOutput per client
  with that client's own buffer: Background Music's shipping driver (BGM_Device.cpp, master) does its
  per-app volume there, keyed by inClientID (ApplyClientRelativeVolume), and says the Thread op is no
  longer per client on recent macOS. A GitHub code search found no shipping driver relying on
  MixOutput. ProcessOutput also leaves WriteMix unchanged, so 'LSmx' = 0 is the 1.1.3 path exactly.
  NOT yet seen in our coreaudiod: harness.c is a fake host, so it proves only our handling. 1.1.4 adds
  'LSst' counters (processOutputCalls, musicClientCalls, othersFramesMoved, musicPID); on the bench
  they must grow with Music + a browser playing, or the approach fails.
- 1.1.4 (build 6): 'LSmx' = Music's pid (0 = off). ProcessOutput: a client whose pid isn't Music's is
  summed into gOthers (indexed by output sample time; the cycle's first such client replaces the
  span, so an unread old lap isn't summed) and zeroed; the HAL's mix is then Music + zeros. The
  loopback input is 4 ch (1-2 gLoop, 3-4 gOthers; both cleared on read); the output stays 2 ch; stream
  formats, the input layout and element names 3-4 are per stream now.
- Compatibility: an engine older than this one (renderA requires 2 ch) reads nothing from a 1.1.4
  device. The plug-in and the app ship together, so the menu's Update installs both; don't pair a
  1.1.4 plug-in with an older build.
- harness.c (fake host, 4 clients: 2 Music, a browser, Facebook): all passed. Music bit-exact on ch 1-2
  incl. the ring wrap, others zeroed before the mix, ch 3-4 = their sum, 'LSmx' = 0 = 1.1.3 (whole mix
  on 1-2, 3-4 silent, buffers untouched), counters.

# Bench: Music only, d59b7ee + plug-in 1.1.4 on the pastor Mac (Babyface Pro), 2026-09-29 10:27-10:40
Data: data/2026-09-29-pastor-musiconly/ (RendererDebugRecord runs silence, alone, with; the .f32 audio,
75 MB, is kept on disk in the benchlog worktree, not in git); scripts
tools/musiconly_bench.sh (on the Mac) and tools/musiconly_check.py. "Another app" = afplay looping
Submarine.aiff to the default output (the virtual device; clients.swift: afplay's pid on
"LosslessSwitcher" only). Track: "Short Glide Tone" (ALAC 44.1k, the DAC's rate: no switch).
- The owner updated the plug-in 1.1.3 -> 1.1.4 from the menu. Before that, d59b7ee with 1.1.3 ran as
  before (2-ch loopback; "no 'LSmx' ... other apps mix into Music").
- coreaudiod calls ProcessOutput per client: 'LSst' after 31 s: 14301 calls, 3505 of them Music's pid,
  5.5 M other-app frames moved (several silent clients as well as afplay). So the ProcessOutput
  approach holds in the real host; MixOutput was never needed.
- silence (Music paused, afplay playing, 37.8 s): A's input (loopback ch 1-2) and B's output (the
  DAC) have 0 nonzero frames. PASS.
- alone vs with (the same track from 0, 30 s each; with = afplay throughout): anchored on a 4096-frame
  chunk 5 s in, found exactly in the other run: 1115953 frames (25.3 s) bit-exact; the only
  differences are the tail, run B's pause fade-out and then A's (each run paused at a different track
  position). Music's fade-in after play/seek makes first-nonzero alignment useless (~0.09 % apart).
  B's output = A's input exactly (1336530 audio frames). PASS: the DAC got only Music, bit-exact.
- Others path: MacBook Pro Speakers, fill 1789-2322 around the 2205 target, varispeed 0.99989-0.99996
  (the speakers ~40-110 ppm apart from the Babyface clock), dry 0x, over 0 while running.
- Step-aside (Music idle 60 s): the player stopped, "music only off ('LSmx' = 0)", 'LSmx' read back 0.
- Alert sounds: with the alert device set to the Babyface, starting the engine left it on MacBook Pro
  Speakers and quitting put it back on the Babyface, also after kill -9 + relaunch. But the engine logged
  no move: macOS moves the alert device off a hogged device by itself (and back on release), before
  startOthers looks. Fix (next commit): the engine reads the alert device before the hog, saves that
  one for the restore, and logs macOS's move; the restore reports "on X again" when macOS already did.

## Found: other apps silent after a rate switch (pastor, feb166c, 10:38-10:41)
The owner played a YouTube video (WebKit GPU process -> the virtual device) and "blurry" in Music
(48k, a take-back with a switch). YouTube was silent. Log: after "restarting the player (the virtual
device's rate is now 48000 Hz)", 19 x "restarting the player (the speakers' configuration changed)" in
0.5 s steps, then no player: our app wasn't a client of the speakers (clients.swift), others ring full
(fill 131072, over 1.65 M), counters still moving YouTube's frames out of Music's channels (the DAC side
was right). Reproduced on Executor (scratchpad avloop.swift): every AVAudioEngine build on the built-in
speakers posts one AVAudioEngineConfigurationChange right after start while it keeps running (3 builds,
3 notices, running true). Restarting on each notice loops; steerOthers only acted on a running player,
so once a rebuild left it stopped nothing restarted it.
Fix: a notice alone isn't a reason; rebuild only if the player stopped or its output left the
speakers (then it is stopped at once: never into the virtual device), at most every 2 s, and keep
retrying while the engine wants other apps there (othersDevice).

## Other Apps & Alerts menu (45a502c), pastor, 2026-09-29 ~10:55
The owner's YouTube on pastor was silent after e501c68 too: the routing worked (WebKit.GPU -> virtual
device, our app a client of MacBook Pro Speakers) but the speakers were muted at -63.5 dB (the Mac's own
setting; not changed). With the volume keys driving the DAC, there was no easy way to reach them. Owner
asked for a device choice and a volume slider in the app.
- Menu (Exclusive Mode on): Other Apps & Alerts: Built-in Speakers (automatic) / any output / Mute
  Other Apps, and Volume… (a window: picker, slider, mute; NSMenu-style MenuBarExtra draws no sliders).
  The slider sets the device's own volume (unmutes when raised); no settable volume -> player gain.
  Default key OtherAppsDeviceUID (nil automatic, "mute", or a UID); the engine follows it each second.
- Pastor: start at 48k, Music switched to 96k: one player restart, no loop (the e501c68 fix held).
  `defaults write ... OtherAppsDeviceUID mute` -> "MUTED (chosen ...)" in 2 s; delete -> back on the
  speakers in 2 s; alerts stayed on MacBook Pro Speakers. The window and slider aren't tested yet (the
  owner, over Remote Desktop).

## Found: other apps silent with 1.1.4 even on unmuted speakers (pastor, 45a502c/a3a8f00, ~11:00)
Owner: "nothing from youtube". Speakers unmuted at -5.3 dB (the owner raised them), our app a client of
MacBook Pro Speakers, WebKit.GPU on the virtual device. a3a8f00's meter: "loopback ch 3-4 peak silent,
player out peak silent" every 10 s, so the loss is in the plug-in (the input stream is 4 ch, stream
configuration [4], checked with tools lsfmt.swift). The earlier afplay "pass" proved only the Music
side (the DAC path silent); ch 3-4 were never measured. My miss.
- Suspected cause (traced, not proven in coreaudiod): 1.1.4's gOthers replaced its span whenever a
  ProcessOutput came with a sample time other than the last one ("first client of a cycle"). If
  coreaudiod gives clients different times, a silent client overwrites an audible one. Harness case
  (two other clients 8 frames apart, one silent): 1.1.4 loses 504 of 512 frames, 1.1.5 none.
- 1.1.5 (b3eeee4): add, except frames past everything written so far (they replace an old lap; a jump
  back of more than half the ring resets). 'LSst' adds othersPeakIn/othersPeakRead and
  othersMaxTimeDelta/othersTimeDeltaCycles; the engine logs them in the 10 s meter line. If the time
  delta reads 0 on the bench, the cause is something else and the peaks say which side.
- 1.1.5 on pastor (owner updated from the menu, ~10:55): YouTube reaches the speakers path. Meter at
  12 s: plug-in peak in 0.5955, read back 0.5955, loopback ch 3-4 -4.5 dBFS, player out -4.5 dBFS,
  MacBook Pro Speakers at -26.7 dB (the owner's slider). So 1.1.4's replace rule was the loss, or
  something it interacted with. The time-delta fields read 0, but they compare only the LAST
  ProcessOutput of a cycle with its WriteMix, so they neither confirm nor rule out differing times
  among the clients: cause traced, not proven. Owner to confirm by ear.
- Owner, by ear on pastor (after PR #4, ba09e5e): YouTube plays from the MacBook Pro Speakers; no
  lip-sync problem noticed. Coffee's plug-in went to 1.1.5 (the owner, from the menu); its engine log
  not checked yet. Still open: the bit-exact Music run on 1.1.5 (needs pastor free).

# Bench: Music only on plug-in 1.1.5 (b3eeee4), pastor Mac, 2026-09-29 11:27
Data: data/2026-09-29-pastor-musiconly-115/ (.f32 on disk only). Same runs as with 1.1.4.
- silence (afplay only, Music paused): A's input and B's output 0 nonzero frames (32.7 s). This time
  the other side was measured too: loopback ch 3-4 and the speakers player peaked at -8.9 dBFS
  (Submarine), so afplay reached the speakers while nothing reached the DAC. PASS.
- alone vs with: 1101105 frames (25.0 s) bit-exact with afplay playing; the only differences are the
  tail (B's pause fade ends +1102205, A's +1111421). with: B's output = A's input (1339090 frames).
  PASS.
- Timestamps: "time delta max 512 frames in 155 cycles": ProcessOutput calls came one buffer
  (512 frames) away from their cycle's WriteMix time, in 155 cycles during the "with" run. So clients
  do arrive with different sample times, which is what 1.1.4's replace rule couldn't survive. That
  supports the cause of the 1.1.4 silence, although it's still a count of the last client per cycle,
  not a direct capture of the loss.
- othersPeakRead measures the left channel only (0.2297 vs 0.3589 in); the engine's meter (both
  channels) read the full 0.3589 (-8.9 dBFS). Cosmetic; noted, not changed.

# Bench: Music only on plug-in 1.1.5 (b3eeee4), coffee (DragonFly Black, int24), 2026-09-29 11:30-11:33
Data: data/2026-09-29-coffee-musiconly-115/ (.f32 on disk only). Track: "The Right Rite" (database ID
8704, ALAC 44.1k, speech; the owner listens on coffee, so no test tone). Owner updated 1.1.3 -> 1.1.5.
- silence: A's input and B's output 0 nonzero frames; afplay on loopback ch 3-4 and the MacBook Air
  Speakers player at -8.9 dBFS. PASS.
- alone vs with: 1103393 frames (25.0 s) bit-exact with afplay playing; differences only in the pause
  fade tail (B ends +1104493, A +1105517). PASS.
- B's recording (float, before int24) = A's input for all 1342324 frames it holds; it ends 78 frames
  before A's (the last of the pause fade), in the alone run as well (no other app): where the
  recording stopped at the quit, not a Music-only effect.
- Other-apps fill sits above target (2600-3570 vs 2205) with varispeed up to 1.000524: the P loop's
  steady offset against the DragonFly's ~1100 ppm-slow clock (DAC scalar 0.998868). ~30 ms extra
  latency at most, no dry-outs or overruns; an integral term would center it (not done).

## Found: wrong rate after skipping forward and back (pastor, b3eeee4, 11:50-11:56)
Owner: Music showed "24-bit 48 kHz" (As Alive As You Need Me To Be, TRON: Ares) while the menu bar
said 44.1 kHz; "it seems to happen when skipping forward and back". Not related to Music only.
- Log: As Alive decided 44.1k on a decoder line 15.465 s before its Playing (no line of its own came);
  Afraid of Time was switched to 48k on a line 0.43 s AFTER its Playing (the "wait 1 s for its own"
  rule took another track's line). On skips Music logs lines for the track it leaves, the one it goes
  to and its pre-roll; a line names no track.
- Music's AppleScript `sample rate of current track` (URL tracks too) polled every 0.3 s over 3 min of
  the owner skipping (tools: /tmp/asrate.sh on pastor): the current track's rate at once for every
  change (Init 48k, Bobby's Song 44.1k, As Alive 48k, Afraid of Time 44.1k x2, No Time for Caution,
  Detach, The Ten Commandments 44.1k), once "missing value" right at the change. Not tested: a hi-res
  track (catalog rate vs the rate Music streams at the owner's quality setting).
- Fix: on a new track, Music's {name, sample rate} of the current track decides when the name matches
  (retries up to ~1 s); a decoder line at that rate only supplies the depth; no answer -> the old
  decoder-line logic. Logs "Music says X Hz" when the newest line disagrees.
- 03e4ffd on pastor: every skip decided by Music's rate ("the newest decoder line says 44100 Hz, Music
  says 48000 Hz for the track; Music's decides" for Init, As Alive, Afraid of Time) and switched right.
  Owner: "it's clearly switching but the taskbar is not". Cause: with Exclusive Mode on, OutputDevices'
  detection returns nothing (the engine owns switching) and the label is only re-read when the
  default output changes (start, stop, step-aside), never at a switch. Fix: applyRate reports the
  rate to OutputDevices.updateSampleRate (the label; it runs no user script while the engine is on).
- 449866b on pastor: owner confirmed the menu bar rate now follows each switch ("perfect").

## Found: wrong-rate start leaks through on skips (pastor, 449866b, 12:06-12:08)
Owner: shuffling a playlist, "glitches at beginning of track" on the Babyface. Data:
data/2026-09-29-pastor-skips/ (engine.log, segments; .f32 on disk only): 10 x `next track` 8 s apart,
6 needed a switch.
- Switches 1 and 6 latched at the gap between the tracks (clean). Switches 2-5 "not latched: cut at the
  play position": B's output before the flush holds 16, 260, 5 and 79 ms of audio after the gap (the new
  track at the old rate).
- Why: Music's decoder line reaches the engine ~0.28 s after Music set the decoder up (log stream
  delivery) and its Playing ~0.25 s after; the new track's audio starts about then, and B trails A by
  only ~46 ms (target 2048 frames). The latch arms after the gap has already gone through.
- Options (for the owner): (1) B trails A by ~0.35 s so a late arm can still mark the gap (retroactive
  latch over a history of A's zero runs), with the plug-in reporting the extra latency so video stays
  in sync; costs ~0.3 s on play/pause/seek response. (2) Hold B at every >=10 ms zero run after audio
  until the engine decides (adds a pause at digital silence mid-track). (3) Cut at B's read position
  instead of A's write position: shortens the leak by ~46 ms at most, doesn't remove it.
- Owner chose option (1). b-trail 0.35 s (targetFill = 0.35 s at the rate; RendererTargetFrames still
  overrides); A keeps a history of gaps (>= 10 ms zeros); a skip's arm and a new track's switch stop B
  at the earliest gap of the last 0.6 s that B hasn't played ("latched at the gap before it, after the
  fact"). Plug-in 1.1.6: 'LSlt' (frames) reported as the output latency (harness: output 15435, input
  0). Not yet on the bench.

# Bench: skips with the 0.35 s trail (4915970, plug-in 1.1.6), pastor, 2026-09-29 ~12:30
Data: data/2026-09-29-pastor-skips-0.35/ (engine.log, segments; .f32 on disk only). Same test: 10 x
`next track` 8 s apart; 7 needed a switch. "virtual device latency -> 15434/16800/33600 frames".
- All 7: "boundary latch: the skip's gap is 13035-30796 frames back, B 1192-3797 frames before it;
  latched there" (6 at the arm; switch 7 at the switch: "latched at the gap before it (after the fact)").
- B's output before each flush: 24376-50944 frames of zeros (B stopped at the gap), then the old track
  (3-8 s run). No new-track audio before any flush (before: 5-260 ms in 4 of 6). PASS.
- Margin is thin: B was 25-85 ms short of the gap when the report came. A later report falls back to
  the old cut at B's read position (a few ms leak). Option if heard: trail 0.5 s. Owner to listen.

## Source depth from the samples (owner: "BUILD IT!"), 2026-09-29 ~12:55
Why: Music logs a decoder line only when it sets one up, not per track (coffee: none for Another Story
and Fear Inoculum over 5 min), so the menu showed "? bit"; AppleScript has no depth for streams (bit
rate missing value).
- A counts Music's nonzero samples off the 16-bit (2^-15) and 24-bit (2^-23) grids. The engine counts
  0.5 s windows in which Music played steadily (no play/pause/track notice within 1 s; the window before
  a pause dropped: Music's pause fade is ~50 ms off every grid, pastor musiconly-115 alone run: 1099
  off-16 samples in the last 0.05 s, none at the play from 0). From 2 s in, with >= 1 s of samples: 16,
  24, or neither (-> Bit-Perfect Check: "Music is changing the samples"). Shown instead of the log's.
- Offline on the 0.35 s skip recording (11 tracks, 8 s each, 0.5 s trimmed at each end): 24-bit
  tracks 99.5-99.7 % off the 16-bit grid, 0 off the 24-bit grid; The Ten Commandments 0 off either
  (16 bit). None "neither".
- 0147f80 on pastor (owner granted Microphone): Short Glide Tone "16 bit (all 44752 on the 16-bit
  grid)"; Oh, Blest Is He That Came (96k) "24 bit (96903 of 97275 samples off the 16-bit grid, all on
  the 24-bit grid)" twice; the hymn at Music volume 90 "neither 16 nor 24 bit (52044 of 1815728
  samples)", Music's log said 24 bit. Volume back to 100. The verdict only rises, so a track flagged
  "neither" stays flagged until the next one.
- Seen in passing: `play (track X)` while another plays gave "not latched: cut at the play position"
  twice (switches 2 and 3): the retroactive gap didn't apply on that path. To look at.

## Checked: `play (track X)` at another rate (pastor, 0147f80, 13:25)
Data: data/2026-09-29-pastor-playtrack/. Hymn (96k, 24 bit) and Short Glide Tone (44.1k, 16 bit)
alternated with `play (track)`, 8 s each, 6 switches. 5 "held at the gate" (Music goes through
Stopped before the new track, so the gate marks its first frame), 1 "latched at the gap before it
(after the fact ... B 115 frames before it)": a 2.6 ms margin. B's output before every flush: zeros,
then the OLD track, identified by its grid (before -> 44.1k: 0.4 % on the 16-bit grid = the 24-bit
hymn; before -> 96k: 99.5 % = the 16-bit tone, less its stop fade). No leak.
- The earlier "not latched" switches 1 and 3: 3 was a take-back (Music paused before setup; nothing in
  the ring to leak); 1 was stale: Music notices queued during the ~5 min Microphone wait were handled
  after setup, one named a track no longer current (Music's rate lookup failed on the name, an old
  decoder line decided). Fix: drop queued Music notices before setUp (it reads Music's state itself).
