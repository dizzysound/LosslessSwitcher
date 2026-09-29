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
