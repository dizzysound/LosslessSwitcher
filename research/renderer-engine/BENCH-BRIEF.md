# Bench test: LosslessSwitcher Dev (Exclusive Mode) on another Mac

You're testing a dev build of LosslessSwitcher (the owner's fork, dizzysound/LosslessSwitcher, branch
`renderer-vdevice`) on a Mac other than the one it was built on. The build's commit is in README.txt.

## What the build does
Music plays to a virtual output device, "LosslessSwitcher" (HAL plug-in LSOutput.driver, installed to
/Library/Audio/Plug-Ins/HAL from the app's menu). Exclusive Mode reads that device's loopback and
plays it, unchanged, to the DAC: the Selected Device, or the default output from before if Selected
Device is "Default Device". It hogs the DAC and uses its non-mixable integer format when the DAC
offers one. The virtual clock is steered to the DAC's. When a track needs a different sample rate, it
pauses Music, switches both devices, rewinds and plays; it catches the boundary at the old track's
end (local files, and Apple Music streams whose next decoder is set up up to ~2 min early). Same-rate
and gapless changes pass through untouched. The volume keys drive the DAC's own volume and mute (4 dB
per step, linear in dB); the audio stays at unity. When Music hasn't played for 60 s the engine steps
aside (DAC un-hogged, the previous default output restored) and takes the output back when Music
plays again ("Advanced > Release DAC When Music Is Idle", on by default). On quit it restores the default
output, un-hogged.

## Setup
1. Unzip into ~/Applications (not an iCloud-synced Desktop or Documents). No setup script is needed.
2. Right-click "LosslessSwitcher Dev.app" > Open the first time (ad-hoc signed).
3. Quit the regular LosslessSwitcher if it runs:
   `osascript -e 'tell application id "com.vincent-neo.LosslessSwitcher" to quit'`
4. Open the dev app. Its menu-bar item is a music note (on a notched MacBook it can hide under the
   notch). Menu: Install Exclusive Mode Driver... (admin password; audio restarts for a moment). It
   turns Exclusive Mode on when done; the toggle is unavailable until the driver is installed. Allow
   the Microphone and Automation (Music) prompts: the engine waits for the Microphone answer and
   leaves the output alone until then.
Engine log: ~/Library/Logs/LosslessSwitcher-ExclusiveMode.log (recreated at each engine start).

## What to test (report with log lines, not assumptions)
1. The DAC: which formats it offers (non-mixable integer or float only), "hog DAC", "DAC format ->",
   "B writes ...", "DAC ready after X s". Switch times (the Babyface Pro: ~1.4 s; the MT 48: 1.6-12 s).
2. Volume keys and mute: the log's "volume: forwarding to DAC ..." line says which controls it uses
   (master element, or the stereo pair's channels) and whether mute is real or emulated. Check the
   DAC's level before and after; restore it.
3. Rate switches by ear, at a track boundary: a local 44.1k track into a 96k one, and an Apple Music
   stream into a different-rate stream. Expect "latched at the old track's end" and "rewound to 0.000".
   AppleScript can't queue tracks: start the first track by double-clicking it in a playlist.
4. Selected Device: pick another output in the app's menu while the engine runs; the engine should
   follow it ("Selected Device changed to ...; following it"). The virtual device is never listed.
5. The built-in speakers as the DAC (mixable float only); the clock lock should report fill ~2048.
6. Music settings window: turn on AutoMix or Sound Check, skip a track: a window lists the fix;
   turn it off, click Check Again, the window closes.
7. Crash recovery: `kill -9` the app. The default should leave the virtual device within ~4 s. Relaunch:
   "at launch: recovering the output after an unclean exit", and no orphaned `perl ... run.pl ... loop`.
8. Restore on quit: the default output back, un-hogged, mixable.
9. Idle step-aside: pause Music for 60 s (or `defaults write com.dizzysound.LosslessSwitcher.dev
   RendererIdleSeconds -float 10` for a quick test, then `defaults delete` it): "Music idle ... stepping
   aside", the DAC un-hogged and the default. Press play: "playback began while stepped aside", then
   "restarts at ..." or a rate switch, and "rewound to ..." about where Music started (not ~1.5 s
   earlier). Note the time from pressing play to sound (Babyface Pro: ~2.2 s).
10. Advanced > Inter-sample Overshoot Protection (off by default): turn it on while playing: the log
   says "inter-sample overshoot protection on: output -3.0 dB, not bit-perfect", Bit-Perfect Check
   lists it, and the level drops by 3 dB (a loopback or level meter on the DAC's output shows it).
   Turn it off: "off: output unchanged". The settings menu is under Advanced; the engine's options
   there show only while Exclusive Mode is on.

## Rules (the owner)
- No gap or pause unless there's a sample-rate switch.
- Restore what you change: default output, its rate, the DAC's volume, Music volume 100. Leave shuffle.
- If anything sounds like loud noise, quit the app at once.
- Plug-in (re)installs need the owner's password, so batch them. Each new copy of an ad-hoc build asks
  again for Microphone and Automation.
- Record findings in research/renderer-engine/log.md (or notes for the owner). Checkpoint and report if
  5-10 attempts yield nothing new.

## Known (don't rediscover)
- Music settings that defeat the engine: AutoMix/Crossfade, Sound Check, EQ, volume below 100.
  AutoMix blends tracks and confuses the boundary logic; turn it off.
- While the engine holds the DAC, picking that DAC in the macOS Sound menu hangs Control Center (beach
  ball) until the engine lets go; the request is ignored. Use the app's Selected Device instead.
- Once, after a quit, Control Center's Sound menu left the DAC out (fixed by `killall ControlCenter`;
  not reproduced). If it happens, first run research/renderer-engine/tools/control-center-refresh.swift.
- One heap-corruption crash in ~45 switches on the MT 48 (not reproduced under ASan). If the app
  crashes, grab ~/Library/Logs/DiagnosticReports/LosslessSwitcher-*.ips.
- Latency ~70-80 ms at 44.1k (accepted).
- Ad-hoc build: no notarization (the owner's Developer account isn't set up); hardened runtime off.

## References
Code: Quality/VirtualDeviceEngine.swift, Quality/VirtualOutputPlugin.swift, HALPlugin/.
History and measurements: research/renderer-engine/log.md.
