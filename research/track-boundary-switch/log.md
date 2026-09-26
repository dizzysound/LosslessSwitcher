# Pause While Switching (local files) — prototype log

Goal: switch the device rate at the track boundary instead of mid-track, and don't resume
until the device has settled. Toggle: "Pause While Switching (Local Files)", default off.

## Design (Quality/TrackBoundarySwitcher.swift)
- Observe `com.apple.Music.playerInfo` (DistributedNotificationCenter). Fires at track start with
  Name, PersistentID (signed Int64), Player State; NO file location. Repeats several times per
  change; each change is "Stopped" then "Playing". AppleScript persistent ID = the Int64 as 16 hex
  digits (checked: -3415280464832900017 -> D09A7C831D4DD44F).
- On a new PersistentID in "Playing": ask Music for the file (LocalTrack, 5 attempts), pick the
  device format with OutputDevices.suitableFormat, and if the device doesn't already match:
  pause -> set format -> wait until nominal rate AND stream physical format match for 4
  consecutive 25 ms reads (5 s timeout; on timeout Music stays paused) -> if Music is still
  paused on the same track, set position 0 and play.
- A local track already playing at launch gets switched once without pausing.

## Things found while testing (2026-09-26, macOS 26.6.2, Neumann MT 48)
1. The app creates OutputDevices twice (AppDelegate and MenuBarController), so upstream already
   runs every detection twice. A switcher per OutputDevices paused/restarted Music twice and
   Music then stalled 7-14 s. Fix: the switcher is owned once, by MenuBarController.
2. The regular path (timer every 2 s for ~10 s after each change) switched local tracks
   mid-playback before the switcher ran. Fix: in pause mode getAllStats leaves local tracks alone.
3. When Music can't report the current track mid-change (-1728 "Can't get current track"), the
   regular path treated it as not local and fell back to the ALAC decoder log line -> mid-track
   switch. Fix: LocalTrack.lookupCurrent returns .unknown and pause mode skips it.
4. The switcher shared processQueue with the regular path, whose AppleScript calls block while
   Music is busy. Fix: its own serial queue.

## Results (live_test.sh: dev build, four direct plays 10 s apart)
| Track | Rate | Paused after track start | Settled after switch | Resumed |
|---|---|---|---|---|
| Backwoods Song | 44.1k | 87 ms | 1095 ms | 1.29 s |
| Skyfall | 96k | 122 ms | 1121 ms | 1.29 s |
| Ventura Highway | 192k | 227 ms | 1172 ms | 1.45 s |
| Bobby's Song | 48k | 123 ms | 1117 ms | 1.29 s |
No AppleScript errors. Device nominal rate (rates.log) changed only while Music was paused.

Natural boundary (natural_test.sh: temp playlist Skyfall 96k -> Backwoods 44.1k, seek to end):
paused 111 ms after Backwoods started, settled 1089 ms, resumed 1254 ms. One earlier run paused
and settled but never resumed; not reproduced. isPaused now logs what Music reported.

## Open
- ~90-230 ms of each rate-changing track plays at the old rate before the pause (the
  notification has no location, so an AppleScript round trip comes first). Restarting at 0:00
  replays it. A lookahead (next track in the current playlist when shuffle is off) could pause
  without that round trip.
- Streams are untouched: their rate is only known from logs after playback starts.
- Not tested: bit-depth switching on, a device other than MT 48, AirPlay, the "resume never
  happened" case above.

## How to run
research/typecheck/check.sh (compile all app sources without Xcode),
research/typecheck/make_dev_app.sh (ad-hoc "LosslessSwitcher Dev.app", bundle id
com.dizzysound.LosslessSwitcher.dev), then live_test.sh / natural_test.sh. Quit the installed
LosslessSwitcher first so the two don't fight over the device.
