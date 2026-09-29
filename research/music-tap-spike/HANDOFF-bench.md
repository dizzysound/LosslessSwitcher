# Bench test: LosslessSwitcher Dev (virtual-device Renderer Engine) on another Mac

You're testing a dev build of LosslessSwitcher (Chris's fork, dizzysound/LosslessSwitcher, branch
`renderer-vdevice`) on a Mac other than the one it was built on. Chris copies the folder
"LosslessSwitcher Dev" (from his main Mac's Desktop) to this Mac.

## What the build does
Music plays to a virtual output device, "LosslessSwitcher" (HAL plug-in LSOutput.driver 1.1.2,
installed to /Library/Audio/Plug-Ins/HAL by the app). The Renderer Engine reads that device's
loopback and plays it to the DAC it was the default before, **hogged, in the DAC's non-mixable
integer format when the DAC offers one**. The virtual clock is steered to the DAC's. At a track
whose sample rate differs, it pauses Music, switches both devices, rewinds and plays. Same-rate and
gapless changes pass through untouched. While the engine runs the virtual device is the default
output; on quit it restores the DAC (mixable, hog released) as the default.

## Setup
1. In the folder: double-click "Set Up (run once).command" (right-click > Open if refused). It puts
   MediaRemoteAdapter's resource bundle at /Users/Shared/LosslessSwitcher-dev-build/... (the
   binary calls fatalError at launch without it) and clears quarantine. Apple Silicon only.
2. Quit the regular LosslessSwitcher if running:
   `osascript -e 'tell application id "com.vincent-neo.LosslessSwitcher" to quit'`
3. Open "LosslessSwitcher Dev.app" (first launch can take ~30 s). Menu-bar item = music note; on a
   notched MacBook it can hide under the notch. Click it via Accessibility if needed:
   `osascript -e 'tell application "System Events" to tell (first process whose bundle identifier is "com.dizzysound.LosslessSwitcher.dev") to click menu bar item 1 of menu bar 2'`
4. Menu: Virtual Output Device > Install... (Chris enters the admin password; coreaudiod restarts),
   then Renderer Engine (Experimental). Chris allows Microphone + Automation (Music) prompts.
Engine log: ~/Library/Logs/LosslessSwitcher-Renderer.log (recreated at each engine start).

## What to test (the point of this session)
1. **Volume keys / mute forwarding** (main goal). The virtual device publishes a volume + mute that
   currently **do nothing** (audio passes at unity). On a DAC with hardware volume/mute (check
   kAudioDevicePropertyVolumeScalar / kAudioDevicePropertyMute on its output, element 0/1/2,
   settable?), find out what the volume keys change and design forwarding: virtual device
   volume/mute -> the DAC's hardware controls (bit-perfect stays intact). Don't implement digital
   scaling in the plug-in without Chris's OK (breaks bit-perfect below 100%).
2. That DAC's behavior: hog + non-mixable accepted? (log: "hog DAC", "DAC format -> ... flags",
   "B writes int32/float32"); switch times (log "DAC ready after X s"; the MT 48's 1.6-12 s is an
   outlier); rate switches clean by ear; restore on quit (`Audio MIDI Setup` / default output).
3. Built-in MacBook speakers as the DAC (no non-mixable format; should fall back to mixable float).
4. Crash recovery: `kill -9` the dev app -> within ~4 s the default leaves the virtual device;
   relaunch -> log "at launch: recovering the output after an unclean exit" and the DAC mixable
   and default again.

## Rules (Chris)
- No gap or pause unless there's a sample-rate switch.
- Restore what you change: default output device, its rate, Music volume 100; leave shuffle as it is.
- The engine writes the device's format at every switch; **if anything sounds like loud noise, quit
  the app at once** (an early build once wrote float samples into an int32 stream; B now stays muted
  until the format is confirmed, log "B writes ...").
- Plug-in (re)installs need Chris's password; batch them. Each copy of an ad-hoc build re-asks for
  Microphone/Automation.
- Record findings (a log.md in the fork's research/renderer-engine/, or notes for Chris) and report
  with evidence (log lines), not assumptions. Checkpoint and report if 5-10 attempts yield nothing new.

## Known open items (don't rediscover)
- One heap-corruption crash in ~45 release switches on the MT 48 (r5), not reproduced under ASan.
  If the app crashes, grab ~/Library/Logs/DiagnosticReports/LosslessSwitcher-*.ips.
- Latency ~70-80 ms at 44.1k (accepted). Boundaries without a pre-roll decoder line (shuffled
  tracks from gapless albums) can't be latched ahead (rare, accepted).
- After a crash macOS falls back to another output (e.g. MacBook speakers) until the app relaunches.
- Xcode build (proper packaging/signing) is planned; this build is SwiftPM + ad-hoc.

## References
- Code: dizzysound/LosslessSwitcher branch renderer-vdevice: Quality/VirtualDeviceEngine.swift,
  Quality/VirtualOutputPlugin.swift, HALPlugin/ (plug-in source, harness, README),
  research/typecheck/make_portable_dev_app.sh (this build), research/renderer-engine/log.md.
- Research + measurements: dizzysound/music-tap-spike branch vdevice, log.md ("Engine port",
  "Plug-in default-device fix"), NEXT.md.
