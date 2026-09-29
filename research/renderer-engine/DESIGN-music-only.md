# Design: Exclusive Mode plays only Music; other apps go to the built-in speakers

Status: designed 2026-09-29, not started. Owner's decisions: other apps' audio goes to the Mac's
built-in speakers; alert/notification sounds go there too. Nothing but Music may reach the DAC.

## Why
The virtual device is the system default output, so every app plays into it and the engine forwards
the mix to the DAC. On the pastor Mac (b321a6a, Babyface) Facebook played through the Babyface while
Exclusive Mode held it. Anything mixed with Music also breaks bit-perfect output.

## Ruled out: switch the main output to the speakers (owner's idea, 2026-09-29)
Exclusive Mode would set the default output to the speakers and revert it when turned off, so other
apps follow it there. But Music has no per-app output: its only local choice is "this computer" (the
default output); the rest are AirPlay devices (coffee: Music's AirPlay devices = "Coffee" (kind
computer) plus AirPlay speakers/TVs). Music would follow the default to the speakers and the virtual
device, hence the DAC, would get nothing. macOS has no public API to route one app to another device.
So the split has to happen inside the virtual device, per client.

## Mechanism (plug-in, LSOutput 1.1.4)
- The engine tells the plug-in Music's pid: new custom property 'LSmx' (CFNumber, 0 = off, mix
  everything as today). Set after setUp, cleared in tearDown; Music relaunching changes the pid
  (musicPID is tracked in the engine).
- Per-client routing in the IO path. AudioServerPlugIn.h: kAudioServerPlugInIOOperationMixOutput
  "mixes the output data into the device's ring buffer ... if a plug-in implements this operation,
  no further output operations will occur for that cycle"; DoIOOperation gets inClientID, and the
  plug-in already maps client IDs to pids (gClient_IDs / gClient_PIDs, AddDeviceClient).
  FIRST TEST: confirm MixOutput is called once per client per cycle with that client's own buffer
  (harness.c, two clients). Fallback if not: ProcessOutput (per-client, before the mix): copy a
  non-Music client's buffer to the others ring and zero it, so WriteMix sees Music + zeros (exact).
- Two rings indexed by output sample time: gLoop (Music, as now) and gOthers (all other clients,
  summed: several apps can play at once). Clear-on-read as today.
- The input (loopback) stream becomes 4 channels: 1-2 = Music (unchanged values), 3-4 = the others.
  The output stream stays 2 ch. Formats are shared between the two streams today (LSOutput.c ~3300,
  ~3334, SetStreamPropertyData ~3420, the "* 8" / "* 2" strides in DoIOOperation ~4620): split them.
  Alternative if 4 ch breaks something: a second input stream (more property plumbing).
- With 'LSmx' = 0 the plug-in behaves exactly as 1.1.3 (engine not running, older engines).

## Engine (VirtualDeviceEngine.swift)
- renderA: accept 4-ch input; channels 1-2 into the ring as now; 3-4 into a second ring (others).
- A third path for the others: AVAudioEngine on the built-in speakers (outputNode's
  kAudioOutputUnitProperty_CurrentDevice), AVAudioSourceNode reading the others ring ->
  AVAudioUnitVarispeed (drift: steer its rate from the others ring's fill, a slow P loop; the virtual
  clock follows the DAC, the speakers have their own crystal) -> output. The engine's rate conversion
  (virtual rate -> speakers' rate) is fine here: this path isn't bit-perfect. Start it only while the
  others ring has non-silent audio, or always while the engine holds the DAC (simpler; decide on the
  bench: the speakers' IO costs little).
- Built-in speakers: the device with transport kAudioDeviceTransportTypeBuiltIn and output streams.
  None (e.g. a Mac mini without speakers, or the DAC is itself built in): mute the others (log it).
- Alerts: set kAudioHardwarePropertyDefaultSystemOutputDevice to the built-in speakers while the engine
  holds the DAC; remember and restore the previous one in tearDown (and in the unclean-exit recovery
  at launch, like the default output).
- Bit-Perfect Check: an item "other apps: to <speakers>" (ok) instead of silently mixing.

## Tests
- harness.c: two clients on the virtual device, one flagged as Music via 'LSmx': loopback ch 1-2 equal
  Music's samples bit-exact while the other plays; ch 3-4 carry the other; 'LSmx' = 0 mixes as 1.1.3.
- Bench (coffee, pastor): Music plus a browser video: the DAC gets only Music (a loopback capture on
  the Babyface via TotalMix, or the engine's debug recorder: RendererDebugRecord), the video plays on
  the speakers; an alert sound plays on the speakers; Exclusive Mode off restores the system output
  device; plug-in 1.1.4 installs from the menu (admin password on each Mac).

## Open questions
- Whether coreaudiod calls MixOutput per client (above); latency of the others path (fine for video?).
- Apps that play through the virtual device's input (none known).
