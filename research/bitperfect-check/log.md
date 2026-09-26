# BitPerfect lessons and the Bit-Perfect Check (2026-09-26)

## What BitPerfect 3.2.0 does (installed app: binary strings, linked symbols, its preferences)
Own player: controls iTunes/Music via AppleScript/ScriptingBridge + iTunesLibrary, pauses it, decodes
the file itself (ExtAudioFileRead), mlock'd buffers, optional SRC (Core Audio / SoX) + dither
(TPDF / noise shaped), software volume with dither, own IOProc (AudioDeviceCreateIOProcID), hog mode,
"integer mode" (kAudioFormatFlagIsNonMixable formats, format ranking by rate/bits/integer),
max device buffer (BufferSize 2048, UseMaxDeviceBufferSize), IOCycleUsage, "minimize iTunes
interaction". The owner's settings: hog on, integer mode on, output = MT 48.
None of hog / integer mode / buffer / IOProc helps an app that doesn't produce the samples: hogging
from LosslessSwitcher would silence Music.

## Applied
1. getFormats drops non-mixable physical formats. The MT 48 lists flags 12 (mixable signed int) and
   76 (+ kAudioFormatFlagIsNonMixable) at every rate; suitableFormat took the first. Verified: the
   app now only sees flags 12.
3. Bit-Perfect Check submenu. Evidence per item, each toggled in Music by the owner:
| Setting | How it's read | on | off |
|---|---|---|---|
| Music volume | AppleScript `sound volume` | verified: 80 -> flagged, 100 -> ok | |
| Sound Enhancer | defaults soundEnhancerEnabled | 1 | key absent |
| Sound Check | defaults optimizeSongVolume | key absent | 0 |
| Dolby Atmos | defaults preferredDolbyAtmosPlaySetting | Automatic: key absent | Off: 30 (Always On not seen) |
| Crossfade | not found anywhere (crossfadeSeconds unchanged) | - | - |
| Equalizer | AppleScript `EQ enabled` reads false while on; can't be set (-10006) | - | - |
| Alert sounds | kAudioHardwarePropertyDefaultSystemOutputDevice vs output device | | |
Crossfade and Equalizer are shown as a manual reminder. Refresh: launch, Music playerInfo
(debounced 3 s, one Apple event), Refresh item.
Harness note: NSAppleScript from a background thread in a command-line tool never returned
(probe/); inside the app it works, so it was tested in the installed app.

## Not applied
2. Prefer the device's highest bit depth instead of the track's in bit-depth mode (Music outputs
   float; a 16-bit physical format truncates without dither whenever gain or mixing is applied).
4. A BitPerfect-style player for local files.

## Review fixes (2026-09-26, before opening the PR)
Adversarial review (5 reviewers, 13 candidates, none >= 80). Fixed anyway:
- Automation usage description now "LosslessSwitcher asks Music about the current track and its
  playback settings." (the old text named local file detection, removed upstream in #74).
- Volume unreadable while Music runs (Automation denied, timeout) -> "couldn't read" item, not
  "Music isn't running".
- Refresh on default output / alert device changes (SimplyCoreAudio notifications) and on the
  menu's Selected Device. Tested: MT 48 -> MacBook Pro Speakers (alert device) -> MT 48 flipped the
  alerts item ok -> REVIEW -> ok with no manual Refresh. Selected Device path not exercised.
- Header comment / commit message: refresh cadence described accurately (any Music player
  notification, at most every 3 s).
- No research/ path cited in code (PR branch has no research/); evidence goes in the PR body.
- PR #227: non-mixable comment reworded; the "would stop Music" claim wasn't tested.
Not tested: the Automation-denied path (would need resetting TCC for the app).
