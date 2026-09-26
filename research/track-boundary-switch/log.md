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

## Round 2 (2026-09-26 16:20): "pauses a little late, resumes before the rate settles, esp. 192k"
Changes: precompiled AppleScripts, rate from Music's `sample rate` (file header only when bit depth
matters), post-settle hold 0.5 s (<=96k) / 1.0 s (>96k).
Pause latency now 62-144 ms (was 87-227). One run showed "not resuming: Music reports playing"; that
was live_test.sh playing the next track during Ventura's 7 s start-up, not Music self-resuming.
Spacing raised to 16 s.

### lockprobe (MT 48): what the device reports after a rate change
Silent IOProc running, every value polled at 5 ms (lockprobe.swift):
| Switch | nominal+physical updated | DeviceIsRunning again | ActualSampleRate stable |
|---|---|---|---|
| 48k -> 96k | 58 ms | 1101 ms | ~1.8 s (96001.2) |
| 96k -> 192k | 63 ms | 1673 ms | ~2.2-3.2 s (192002.2) |
ClockIsStable ('cstb') = 1 throughout; latency, clock source unchanged; safety offset changes with rate.
=> The nominal/physical check passes ~60 ms after the switch and is not a readiness signal.
The device is really back when it is running again, and its measured rate (ActualSampleRate,
AudioTimeStamp rate scalar) has stopped moving. Reading those needs the device running, so the
switcher must run a silent IOProc while Music is paused.

Probe gotchas: stdout to a pipe lost output (use setvbuf line buffering); runs started while Music
was paused exited 133 (trap) before printing, cause not found yet; runs while Music played worked.

### Next
1. Readiness = own silent IOProc, then wait for DeviceIsRunning and ActualSampleRate within a
   tolerance and stable over ~250 ms, then stop the IOProc and resume.
2. Short / Normal / Long extra gap setting on top (the owner's suggestion), for DACs whose lock
   lags what the HAL reports.

## Round 3 (2026-09-26 16:35): readiness from the device + Short/Normal/Long gap
The earlier "exit 133" probe crashes were zsh not word-splitting `$pair` (missing argument ->
index trap), not Music being paused. With Music paused (lockprobe_paused.txt):
| Switch | first running | running steadily | ActualSampleRate within 0.5% |
|---|---|---|---|
| 96k -> 192k | 1.24 s | 1.52 s (ran/stopped 3x) | 2.02 s |
| 192k -> 44.1k | 1.09 s | 1.09 s | ~2.56 s (starts 6.5% off, 46953 Hz) |
| 44.1k -> 96k | 1.35 s | 1.44 s | 1.94 s |

Readiness now: SilentOutput (own IOProc writing zeros) started before the switch; ready when
nominal+physical match, the device has run for 0.5 s without stopping, and ActualSampleRate has
been measured (not the exact-nominal placeholder) within 0.5% (or 2 s of steady running if never
measured). Then the gap (Short 0 / Normal 0.25 s / Long 1 s), resume, and stop the silent output
0.5 s later so the device doesn't stop between. Timeout 8 s leaves Music paused.

live_test.sh, Normal gap:
| Change | paused after start | ready after switch | resumed after start |
|---|---|---|---|
| to 44.1k | 66 ms | 2349 ms | 2738 ms |
| to 96k | 66 ms | 2106 ms | 2521 ms |
| to 192k | 81 ms | 2204 ms | 2604 ms |
| to 48k | 138 ms | 1632 ms | 2123 ms |
Not yet judged by ear; the owner to try Short/Normal/Long.

## Round 4 (2026-09-26 16:50): "Music controls sometimes unresponsive"
No Music hang/spin reports; Music answered `player state` in 0.10-0.19 s; no CPU load. Our code:
1. The regular path's timer (2 s x 5 after each change, x2 duplicate OutputDevices, plus 1 s
   retries) asked Music about the current track: >=116 Apple events in ~70 s / 4 changes (~29 per
   change), clustered at track changes. Music answers Apple events on its main thread.
   Fix: in pause mode the switcher asks once per track and publishes currentTrackKind; the regular
   path reads that and never asks Music. Measured after: 0 regular-path lookups.
2. The switcher ignored the user for its ~2.5 s wait: play pressed -> we restarted anyway later
   (only if still paused); skip -> queued behind the wait. Fix: track our pause (pausing -> paused
   once Music's "Paused" notification arrives); any later "Playing", or a new track, cancels the
   wait. intervene_test.sh: play during wait -> "user took over", Skyfall kept playing; skip during
   wait -> cancelled at once, next track paused 69 ms in, switched, resumed at 2.8 s.
Still not detectable: pressing PAUSE during our wait (Music is already paused, no notification),
so the track still resumes. Detect Local Files without pause mode still polls like upstream.
Test harness: `script -q` without -F lost all output in one run; use `script -q -F`.

## Round 5 (2026-09-26 17:05): MacBook Pro Speakers
Rates 44.1/48/88.2/96k. lockprobe_speakers.txt: running again 126-254 ms after the switch, no
start/stop flapping, first ActualSampleRate measurement ~0.8-0.9 s and already within ~10 ppm.
`DEV="MacBook Pro Speakers" ./live_test.sh`, Normal gap:
| Change | paused after start | ready after switch | resumed after start |
|---|---|---|---|
| to 44.1k | 62 ms | 848 ms | 1222 ms |
| to 96k | 65 ms | 1010 ms | 1384 ms |
| 192k track | no pause: nearest supported is 96k, already set | | |
| to 48k | 141 ms | 1000 ms | 1450 ms |
Regular-path lookups: 0. Readiness here is bounded by the HAL's first clock measurement (~0.8 s),
not by the device; the 2 s unmeasured fallback never came into play.

## Round 6 (2026-09-26 17:30): one OutputDevices; intermittent MT 48 "not ready"
Removed the duplicate OutputDevices/MediaRemoteController in AppDelegate (it now reads
MenuBarController.shared.outputDevices). The duplicate ran all detection twice and never saw the
menu's Selected Device, so it acted on the default device. After: "track" log lines per change
halved (30 -> 15), "same track" retries 59 -> 27.

New: Skyfall (44.1k -> 96k, second track of live_test.sh) sometimes times out:
  not ready: matches=true running=false ... steadyFor=0.02 s   (device starts/stops for the full 8 s)
Occurrences, 44.1k -> 96k on the MT 48:
| Test | timeouts |
|---|---|
| live_test.sh before the dedupe (rounds 3-4) | 0/4 |
| live_test.sh after the dedupe | 3/5 (one with NO_RATES=1, so not the audioctl sampler) |
| repeat_test.sh (alternating, no sampler) | 0/4 |
No mechanism found linking the dedupe to device behavior (the removed instance never touched the
device). The owner: the MT 48 misbehaves on newer macOS, and IP-based devices will be less regular.
Open: restart SilentOutput when the device keeps stopping? Resume vs stay paused after the timeout
(pressing play already cancels the wait).

## Round 7 (2026-09-26 17:45): restart the silent output when the device keeps stopping
From 2.5 s after the switch, if the device has been stopped >= 0.25 s, restart SilentOutput (at
most every 1.5 s); count starts. 3 x `NO_RATES=1 ./live_test.sh` on the MT 48: 12/12 ready, no
timeouts (before: 3/5 live_test runs timed out on 44.1k -> 96k). The stall recurred once (run 1,
Skyfall): "device keeps stopping (6 starts); restarting silent output" -> "ready after 7 starts,
1 keep-alive restarts", ready 4358 ms after the switch. One rescue observed; not yet proof that the
restart (rather than the device) ended the stall.

## Round 8 (2026-09-26 18:05): review fixes (PR #227)
1. The switcher's device changes now go through OutputDevices.applySerialized (processQueue.sync),
   and switchLatestSampleRate re-checks currentTrackKind right before applying, so a stale stream
   rate can't land in the middle of the switcher's wait.
2. If SilentOutput can't start (e.g. another app hogs the device), wait for the format change only,
   then the gap, instead of a certain 8 s timeout. Not exercised.
3. currentTrackKind is refreshed whenever the toggle turns on (Combine sink, also fires at launch).
   Tested: Skyfall 96k playing, MT 48 forced to 48k, launch -> 96k within 6 s, Music kept playing.
Regression live_test.sh: 4/4 resumed. New stall variant: Skyfall "ready after 51 starts, 0 keep-alive
restarts", 6372 ms. The device flapped fast enough never to be stopped for 0.25 s, so the restart
never fired; it settled by itself. Open: also restart on a high start count?

## Context (2026-09-26): the MT 48 start/stop flapping is not LosslessSwitcher
Per the owner, and the Rogue Amoeba support thread "Loopback 2.4.10 — Virtual device continuously
recycling HAL objects" (May–Sep 2026): Rogue Amoeba tracks Core Audio issues on macOS 26 involving
aggregate devices and sample-rate mismatches (filed with Apple; mitigation: keep the whole chain at
one rate). The owner's 2026-09-19 instrumentation named short-lived system audio processes
(systemsoundserverd + corespeechd ~3 s lifetimes; sirittsd, Sound.appex) causing CoreAudio object
churn even with everything at 48 kHz; RME's DriverKit driver separately caused ~700 ms teardowns
(fixed by the 3.39 kext). This Mac: arkaudiod running, systemsoundserverd/corespeechd present, no
aggregate containing the MT 48 (aggregates.swift). Much better than it used to be.
Note: switching rates is inherently at odds with "keep every rate matched" (Loopback Audio stays 48k).
The keep-alive restart stays as a mitigation, not a fix. Not checked: whether the flapping lines up
with those processes' launches.

## Round 9 (2026-09-26 17:40): Apple Music streams not switching in pause mode
The owner: installed build "broke Apple Music switching". Library Apple Music tracks still switched
(Arcade Fire 96k). Non-library streams (stations, Browse; AppleScript class "URL track") did not:
com.apple.Music.playerInfo for them has Name/Artist/Album/Total Time but NO PersistentID
(notif_url.log). playerInfoDidChange required a PersistentID, so currentTrackKind kept the previous
local track's .local and getAllStats returned [] for the stream.
Fix: "Playing" without PersistentID -> currentTrackKind = .notLocal, lastPersistentID = nil (local
files are always library tracks). Verified: Skyfall (local, 96k) then the owner's station -> log
"stream without PersistentID", ALAC log line 44.1k detected, MT 48 96k -> 44.1k.

## Round 10 (2026-09-26 17:45): mid-song switch on an Apple Music station
The owner heard a rate change mid-song. Traced (system log, 17:39): while "Enfold" (44.1k) was ~2:10 in,
Music queued the station's next item and pushed a now-playing metadata update (17:39:29.5);
mediaremoted posted kMRMediaRemoteNowPlayingInfoDidChangeNotification; the app's MediaRemoteAdapter
helper picked it up -> MediaRemoteController -> trackDidChange -> switchLatestSampleRate 1 s later.
At 17:39:30.2 Music had opened a 48k ALAC decoder for the prefetched next track, so the newest log
line in the 5 s window was 48k -> MT 48 switched 44.1k -> 48k mid-song. Upstream code path (not the
switcher); its only guard blocks down-switches on the same track, and 44.1 -> 48 is up.
Fix: trackDidChange still records previous/current track but only runs detection on a real track
change (the post-change timer is unchanged).
Verification: prefetch_test.sh (installed build, station) 3.5 + 10 min, 5 tracks: rate changed only
at track changes (e.g. Shadows 48k -> Murmurations 44.1k at the boundary). One mid-track prefetch
decoder line (17:46:29, 44.1k, same rate as current) and no mid-track now-playing update occurred,
so the exact trigger was NOT reproduced; the fix is reasoned from the 17:39 evidence.
