// renderer <seconds> <outprefix> <log> [--mute muted|whenTapped|unmuted] [--monall] [--nomonitor]
//          [--silent] [--inplace]
// Prototype renderer: taps Music's output on the default output device (MT 48) with Music's own
// output muted, and passes the tap's channels 1-2 to that device inside one private aggregate
// whose main/clock device is the device itself (tap and output share a clock, no drift
// compensation). A second "monitor" tap on the same device, excluding Music (or nobody with
// --monall), records what the HAL mixes for the device, so the output can be null-tested against
// the Music tap. --silent writes zeros instead of the tap (for listening checks).
// Rate changes: the file <prefix>.cmd is polled for "rate <hz>" lines. By default a rate change
// destroys the aggregate and both taps, sets the device rate, waits until the device reports it,
// and builds a fresh tap + aggregate ("rebuild"). --inplace just sets the rate under the running
// aggregate (the earlier behavior, where the Music tap broke after a switch).
// --follow: Music's IsRunningOutput is polled every 10 ms (it doesn't notify); whenever Music's
// output (re)starts, or Music posts com.apple.Music.playerInfo "Playing", a rebuild is armed; it
// happens once Music is Playing (by the latest playerInfo), its output has run for --settle ms
// (default 300) and no playerInfo arrived for that long. A `rate` command only tears down and sets
// the rate, leaving the rebuild to the trigger. A healthy pipeline (built while Music was Playing,
// at the current rate) is kept: gapless track changes post Playing without restarting Music's
// output, and a rebuild there would hand off between Music's direct output and ours mid-music.
// Why: Music's output flaps on/off every ~100 ms while
// the MT 48 starts and restarts on every rate change even while paused, and a tap built while
// Music is paused got nothing once playback started (rb2, rb5, fw2).
// Hog mode / non-mixable formats were dropped: they can't coexist with tapping Music on the same
// device (see log.md).
// Writes <prefix>.tap.f32 (Music tap ch 1-2), <prefix>.out.f32 (what the IOProc wrote to ch 1-2),
// <prefix>.mon.f32 (monitor tap ch 1-2), all float32 interleaved stereo, one row per aggregate
// frame and continuous across rebuilds; <prefix>.cycles.txt (per IO cycle: sample time, frames,
// pipeline generation) and <prefix>.segments.txt (first frame and rate of each pipeline).
// --auto (implies --follow): automatic rate switching. Music logs "Input format: ... <rate> Hz" (subsystem
// com.apple.coreaudio) each time it sets up a decoder, including the real rate of Apple Music
// streams, and for a local next track it does so ~12 s ahead (pre-roll). A `log stream` child
// process watches for these lines; the new track's rate is the latest one seen before its
// playerInfo "Playing". The Playing notification arrives ~50 ms after the new track's first samples
// reach the tap, so the renderer delays its output by --delay ms (default 200): on a rate mismatch it
// silences the output and clears the delay line at once (the new track's wrong-rate start is still
// in it), pauses Music and rewinds the track to 0:00 (AppleScript), tears down, sets the device rate,
// waits --switchwait ms (default 1000) and resumes; the follow trigger then rebuilds the tap.
// Session 2 (--auto): the "switch routine" replaces that (--switchwait now defaults to 0; a silent
// keep-alive IOProc + readiness wait, ported from LosslessSwitcher, replaces it). It runs whenever Music posts Playing and
// either the new track's rate differs from the device's or there is no pipeline built while Music
// was playing (first play after launch). Output muted, Music paused, its position noted, its
// volume set to 0, pipeline torn down, rate set, Music played silently until its output is steady,
// pipeline built, volume restored, then Music is rewound to where the track (or the resume) started
// (--rewind pause: pause, set position, wait for the tap to go quiet, unmute, play; --rewind seek:
// set position while playing; --rewind none: just unmute). So the delay line's 200 ms of silence
// falls inside the switch pause instead of inside the track. At launch Music's volume is set to 0
// (so the first play is silent until the routine has a pipeline) and restored on exit. The old
// "health" trigger (tap exactly 0 for > 1 s) is gone: it fired on tracks' own digital silence.
import AppKit
import CoreAudio
import Foundation

func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    .init(mSelector: s, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func stringProp(_ obj: AudioObjectID, _ s: AudioObjectPropertySelector) -> String {
    var a = addr(s); var v: Unmanaged<CFString>?; var z = UInt32(MemoryLayout<CFString?>.size)
    AudioObjectGetPropertyData(obj, &a, 0, nil, &z, &v); return (v?.takeRetainedValue() as String?) ?? ""
}
func fmt(_ f: AudioStreamBasicDescription) -> String { "\(f.mSampleRate) Hz \(f.mChannelsPerFrame) ch \(f.mBitsPerChannel) bit flags \(f.mFormatFlags)" }
func nominal(_ dev: AudioObjectID) -> Float64 { var r: Float64 = 0; var a = addr(kAudioDevicePropertyNominalSampleRate); var z = UInt32(8); AudioObjectGetPropertyData(dev, &a, 0, nil, &z, &r); return r }
func tapFormat(_ tap: AudioObjectID) -> AudioStreamBasicDescription {
    var f = AudioStreamBasicDescription(); var a = addr(kAudioTapPropertyFormat); var z = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    AudioObjectGetPropertyData(tap, &a, 0, nil, &z, &f); return f
}
let t0 = Date()
func idle(_ s: Double) { RunLoop.current.run(until: Date().addingTimeInterval(s)) }
func log(_ s: String) { print(String(format: "[%7.3f] ", Date().timeIntervalSince(t0)) + s) }

let args = CommandLine.arguments
guard args.count >= 4, let seconds = Double(args[1]) else { print("usage: renderer <seconds> <outprefix> <log> [options]"); exit(1) }
freopen(args[3], "w", stdout); freopen(args[3], "a", stderr); setvbuf(stdout, nil, _IOLBF, 0)
let prefix = args[2]
func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
// The monitor tap (everyone but Music, on the same device) is a test instrument. It is off by
// default in --auto (--monitor turns it on): with it, 6 of 57 switches into 192k got corrupted
// audio from Music; without it 0 of 66 (log.md, "192k corruption: bisect").
let monitor = args.contains("--auto") ? args.contains("--monitor") : !args.contains("--nomonitor"), monAll = args.contains("--monall")
// Bisecting the 192k corruption (log.md): --nokeepalive skips the SilentOutput and waits a fixed
// 3.5 s after the rate set (as repro192.sh does); --taponly records only the Music tap (long runs).
let noKeepAlive = args.contains("--nokeepalive"), tapOnly = args.contains("--taponly")
let silent = args.contains("--silent"), inplace = args.contains("--inplace")
let muteMode = opt("--mute") ?? "muted"
let auto = args.contains("--auto")
let switchWait = Double(opt("--switchwait") ?? (args.contains("--auto") ? "0" : "1000"))! / 1000
let follow = auto || args.contains("--follow"), settle = Double(opt("--settle") ?? (args.contains("--auto") ? "120" : "300"))! / 1000
// --auto hold/rewind trims (session 3): settle 120 ms (was 300), volume restored while paused for
// the rewind (was 150 ms before it), tap quiet --quiet ms (default 40, was 100) before unmuting.
let quietSec = Double(opt("--quiet") ?? "40")! / 1000
log("args: \(args.dropFirst().joined(separator: " "))")

guard let music = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first else { log("Music isn't running"); exit(1) }
var pid = music.processIdentifier
var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
var musicObj = AudioObjectID(0); var size = UInt32(MemoryLayout<AudioObjectID>.size)
var st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &musicObj)
guard st == noErr, musicObj != 0 else { log("no process object for Music (\(st))"); exit(1) }
a = addr(kAudioHardwarePropertyDefaultOutputDevice)
var dev = AudioObjectID(0); size = 4
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &dev)
let uid = stringProp(dev, kAudioDevicePropertyDeviceUID)
log("device \(stringProp(dev, kAudioObjectPropertyName)) @ \(nominal(dev)) Hz; Music process object \(musicObj); mute \(muteMode); rate changes: \(inplace ? "in place" : "rebuild")")

// Recording state, shared by every pipeline generation (written only on the IO thread).
let maxFrames = Int((seconds + 2) * 200000)
let tapRec = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2); tapRec.initialize(repeating: 0, count: maxFrames * 2)
let recFrames = tapOnly ? 1 : maxFrames
let outRec = UnsafeMutablePointer<Float>.allocate(capacity: recFrames * 2); outRec.initialize(repeating: 0, count: recFrames * 2)
let monRec = UnsafeMutablePointer<Float>.allocate(capacity: recFrames * 2); monRec.initialize(repeating: 0, count: recFrames * 2)
let maxCycles = 400000
let cycSample = UnsafeMutablePointer<Float64>.allocate(capacity: maxCycles)
let cycFrames = UnsafeMutablePointer<Int32>.allocate(capacity: maxCycles)
let cycGen = UnsafeMutablePointer<Int32>.allocate(capacity: maxCycles)
let cycHost = UnsafeMutablePointer<UInt64>.allocate(capacity: maxCycles)
var frames = 0, cycles = 0, missingTap = 0, generation = 0, lastTapNZ = 0
// Output delay line (IO thread only, except `muteOut`/`clearDelay`, set by the main thread).
let delaySec = Double(opt("--delay") ?? (auto ? "200" : "0"))! / 1000
let ringSize = 1 << 19  // frames; > 1 s at 384 kHz
let ring = UnsafeMutablePointer<Float>.allocate(capacity: ringSize * 2); ring.initialize(repeating: 0, count: ringSize * 2)
var ringW = 0, delayFrames = 0
var muteOut = false, clearDelay = true
// Boundary latch (sr1: Music can post Playing 130-380 ms into the next track, past the delay line).
// When the next track needs another rate, the main thread arms this for the old track's last
// ~1.5 s; the IO thread then stops feeding the delay line at the first >= 10 ms of exact zeros
// (Music leaves >= 82 ms of zeros between tracks at every rate change in sr1). The old track's
// tail still plays out of the delay line; the new track's wrong-rate start never enters it.
var armed = false, muteIn = false, zeroRun = 0, armZero = 441, latchFrame = 0
var segments: [String] = []

// One pipeline = Music tap (+ monitor tap) + private aggregate + IOProc.
struct Pipeline { var musicTap: AudioObjectID; var monTap: AudioObjectID; var agg: AudioObjectID; var proc: AudioDeviceIOProcID }
var pipe: Pipeline?
var tapFmtEvents = 0
let listenQ = DispatchQueue(label: "listen")

func buildPipeline() -> Pipeline? {
    generation += 1
    let gen = Int32(generation)
    func makeTap(_ d: CATapDescription, _ name: String) -> AudioObjectID {
        d.uuid = UUID(); d.isPrivate = true; d.name = name
        var t = AudioObjectID(0); let s = AudioHardwareCreateProcessTap(d, &t)
        if s != noErr { log("create tap \(name) failed \(s)"); return 0 }
        return t
    }
    let md = CATapDescription(processes: [musicObj], deviceUID: uid, stream: 0)
    md.muteBehavior = muteMode == "unmuted" ? .unmuted : (muteMode == "whenTapped" ? .mutedWhenTapped : .muted)
    let mt = makeTap(md, "renderer-music")
    guard mt != 0 else { return nil }
    var tapList: [[String: Any]] = [[kAudioSubTapUIDKey: md.uuid.uuidString, kAudioSubTapDriftCompensationKey: 0]]
    var monTap = AudioObjectID(0)
    if monitor {
        let d = CATapDescription(excludingProcesses: monAll ? [] : [musicObj], deviceUID: uid, stream: 0)
        d.muteBehavior = .unmuted
        monTap = makeTap(d, "renderer-monitor")
        if monTap != 0 { tapList.append([kAudioSubTapUIDKey: d.uuid.uuidString, kAudioSubTapDriftCompensationKey: 0]) }
    }
    let aggDesc: [String: Any] = [
        kAudioAggregateDeviceUIDKey: UUID().uuidString, kAudioAggregateDeviceNameKey: "renderer",
        kAudioAggregateDeviceIsPrivateKey: 1, kAudioAggregateDeviceMainSubDeviceKey: uid,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
        kAudioAggregateDeviceTapListKey: tapList, kAudioAggregateDeviceTapAutoStartKey: 1,
    ]
    var agg = AudioObjectID(0)
    let s = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
    guard s == noErr else { log("create aggregate failed \(s)"); AudioHardwareDestroyProcessTap(mt); if monTap != 0 { AudioHardwareDestroyProcessTap(monTap) }; return nil }
    var tfAddr = addr(kAudioTapPropertyFormat)
    AudioObjectAddPropertyListenerBlock(mt, &tfAddr, listenQ) { _, _ in tapFmtEvents += 1 }

    var procID: AudioDeviceIOProcID?
    let ps = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) { _, inInput, inTime, outOutput, _ in
        let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
        let outs = UnsafeMutableAudioBufferListPointer(outOutput)
        guard let ob = outs.first, let od = ob.mData else { return }
        let och = Int(ob.mNumberChannels), n = Int(ob.mDataByteSize) / 4 / och
        // input buffers: [device inputs, Music tap, monitor tap]
        let hasMon = monTap != 0
        let tapIdx = ins.count - (hasMon ? 2 : 1)
        let haveTap = tapIdx >= 1
        let tch = haveTap ? max(Int(ins[tapIdx].mNumberChannels), 1) : 1
        let tn = !haveTap || ins[tapIdx].mData == nil ? 0 : min(n, Int(ins[tapIdx].mDataByteSize) / 4 / tch)
        let td = haveTap ? ins[tapIdx].mData?.assumingMemoryBound(to: Float.self) : nil
        if !haveTap { missingTap += 1 }
        let o = od.assumingMemoryBound(to: Float.self)
        if clearDelay { ring.update(repeating: 0, count: ringSize * 2); clearDelay = false }
        let mute = muteOut
        var latched = muteIn
        for f in 0..<n {
            let l: Float = f < tn ? td![f * tch] : 0, r: Float = f < tn ? td![f * tch + 1] : 0
            if l != 0 || r != 0 { lastTapNZ = frames + f }
            if armed && !latched {
                if l == 0 && r == 0 { zeroRun += 1; if zeroRun >= armZero { latched = true; muteIn = true; armed = false; latchFrame = frames + f } } else { zeroRun = 0 }
            }
            // delay line: write the tap in (zeros while muted or latched), read delayFrames behind
            let wi = (ringW & (ringSize - 1)) * 2
            let zin = mute || latched
            ring[wi] = zin ? 0 : l; ring[wi + 1] = zin ? 0 : r
            let ri = ((ringW - delayFrames) & (ringSize - 1)) * 2
            ringW += 1
            let (ol, or) = silent || mute ? (Float(0), Float(0)) : (ring[ri], ring[ri + 1])
            o[f * och] = ol; o[f * och + 1] = or; for c in 2..<och { o[f * och + c] = 0 }
            let k = frames + f
            if k < maxFrames { tapRec[k * 2] = l; tapRec[k * 2 + 1] = r }
            if k < recFrames { outRec[k * 2] = ol; outRec[k * 2 + 1] = or }
        }
        if hasMon, haveTap, let mdata = ins[ins.count - 1].mData {
            let mch = Int(ins[ins.count - 1].mNumberChannels), mn = min(n, Int(ins[ins.count - 1].mDataByteSize) / 4 / mch)
            let m = mdata.assumingMemoryBound(to: Float.self)
            for f in 0..<mn where frames + f < recFrames { monRec[(frames + f) * 2] = m[f * mch]; monRec[(frames + f) * 2 + 1] = m[f * mch + 1] }
        }
        if cycles < maxCycles { cycSample[cycles] = inTime.pointee.mSampleTime; cycFrames[cycles] = Int32(n); cycGen[cycles] = gen; cycHost[cycles] = inTime.pointee.mHostTime }
        cycles += 1; frames += n
    }
    guard ps == noErr, let procID else { log("IOProc failed \(ps)"); return nil }
    segments.append("\(frames) \(nominal(dev))")
    delayFrames = Int(delaySec * nominal(dev)); clearDelay = true
    let c0 = cycles, tStart = Date()
    let ss = AudioDeviceStart(agg, procID)
    while cycles == c0 && Date().timeIntervalSince(tStart) < 15 { idle(0.002) }
    log("pipeline \(generation): aggregate @ \(nominal(agg)) Hz, Music tap \(fmt(tapFormat(mt))); start \(ss); first IO cycle after \(String(format: "%.3f", Date().timeIntervalSince(tStart))) s")
    return Pipeline(musicTap: mt, monTap: monTap, agg: agg, proc: procID)
}
func teardown(_ p: Pipeline) {
    AudioDeviceStop(p.agg, p.proc)
    AudioDeviceDestroyIOProcID(p.agg, p.proc)
    AudioHardwareDestroyAggregateDevice(p.agg)
    AudioHardwareDestroyProcessTap(p.musicTap)
    if p.monTap != 0 { AudioHardwareDestroyProcessTap(p.monTap) }
}
func setDeviceRate(_ hz: Float64) -> OSStatus {
    var r = hz; var a = addr(kAudioDevicePropertyNominalSampleRate)
    return AudioObjectSetPropertyData(dev, &a, 0, nil, 8, &r)
}
// Music volume (AppleScript); --auto holds it at 0 while there's no pipeline built while playing.
var savedVolume = 100
func runScript(_ src: String) -> Bool {
    var err: NSDictionary?; _ = NSAppleScript(source: src)?.executeAndReturnError(&err)
    if let err { log("AppleScript error: \(err)") }; return err == nil
}
func scriptValue(_ src: String) -> NSAppleEventDescriptor? {
    var err: NSDictionary?; let d = NSAppleScript(source: src)?.executeAndReturnError(&err)
    if let err { log("AppleScript error: \(err)") }; return err == nil ? d : nil
}
func setVolume(_ v: Int) { _ = runScript("tell application \"Music\" to set sound volume to \(v)") }
var sigSources: [DispatchSourceSignal] = []
for sig in [SIGTERM, SIGINT] {
    signal(sig, SIG_IGN)
    let src = DispatchSource.makeSignalSource(signal: sig, queue: .main)
    src.setEventHandler { if let p = pipe { teardown(p) }; if auto { setVolume(savedVolume) }; exit(2) }
    src.resume(); sigSources.append(src)
}

var rateAddr = addr(kAudioDevicePropertyNominalSampleRate)
AudioObjectAddPropertyListenerBlock(dev, &rateAddr, listenQ) { _, _ in log("device nominal rate -> \(nominal(dev))") }

func musicRunning() -> Bool { var r = UInt32(0); var a = addr(kAudioProcessPropertyIsRunningOutput); var z = UInt32(4); AudioObjectGetPropertyData(musicObj, &a, 0, nil, &z, &r); return r != 0 }
// Register for playerInfo before building the first pipeline, so a Playing posted while it builds
// isn't missed (fw3/fw4 missed the first one and so never rebuilt after Music's startup flapping).
var rebuildPending = false
var pipeBuiltPlaying = false, pipeRate: Float64 = 0
func needsRebuild() -> Bool { pipe == nil || !pipeBuiltPlaying || nominal(dev) != pipeRate }
var playing = false, lastInfo = Date.distantPast
// --auto: Music's decoder log lines -> (arrival time, rate)
var decoderRates: [(Date, Float64, Bool)] = []   // (arrival, rate, lossless); main thread only
// Apple Music streams can start on a lossy 48k decoder and set up the lossless one seconds later
// (sw1: AAC 48k, then ALAC 96k 2.5 s on). A lossless line within 10 s of a track detected from a
// lossy line triggers another switch.
var lossyTrackAt: Date? = nil, pendingUpgrade: Float64? = nil, armAt: Date? = nil, armedAt = Date.distantPast
var lastTrackID: Int64? = nil, autoSwitches = 0
var logProc: Process? = nil
if auto {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    p.arguments = ["stream", "--style", "compact", "--predicate", "process == \"Music\" AND eventMessage CONTAINS \"Input format:\""]
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    var partial = ""
    out.fileHandleForReading.readabilityHandler = { h in
        guard let chunk = String(data: h.availableData, encoding: .utf8), !chunk.isEmpty else { return }
        DispatchQueue.main.async {
            partial += chunk
            var lines = partial.components(separatedBy: "\n"); partial = lines.removeLast()
            for line in lines {
                guard let r = line.range(of: "Input format:") else { continue }
                let rest = line[r.upperBound...]
                guard let hz = rest.range(of: #"[0-9]+ Hz"#, options: .regularExpression) else { continue }
                let rate = Float64(rest[hz].dropLast(3))!
                let lossless = line.contains("lac")
                if decoderRates.last?.1 != rate || Date().timeIntervalSince(decoderRates.last!.0) > 0.5 {
                    log("decoder: \(rate) Hz (\(lossless ? "lossless" : "lossy"))")
                }
                if lossless, let at = lossyTrackAt, Date().timeIntervalSince(at) < 10 { pendingUpgrade = rate; lossyTrackAt = nil }
                // a decoder for another rate while a pipeline plays: the next track (local tracks are
                // pre-rolled 8-12 s ahead; streams ~60 ms ahead) -> arm the boundary latch near the end
                if auto, !inRoutine, playing, pipe != nil, rate != nominal(dev), !armed, !muteIn, armAt == nil {
                    let pos = scriptValue("tell application \"Music\" to get player position")?.doubleValue ?? 0
                    let dur = scriptValue("tell application \"Music\" to get duration of current track")?.doubleValue ?? 0
                    armAt = Date().addingTimeInterval(max(0, dur - pos - 1.5))
                    log("auto: next track needs \(rate) Hz; \(String(format: "%.2f", dur - pos)) s left, arming the boundary latch in \(String(format: "%.2f", max(0, dur - pos - 1.5))) s")
                }
                decoderRates.append((Date(), rate, lossless)); if decoderRates.count > 200 { decoderRates.removeFirst(100) }
            }
        }
    }
    try? p.run(); logProc = p
    log("watching Music's decoder log (pid \(p.processIdentifier))")
}
// --auto: a pending switch routine (set by the playerInfo observer, run by the main loop)
struct SwitchRequest { var rate: Float64?; var name: String; var reason: String; var tPlay: Date }
var request: SwitchRequest? = nil, inRoutine = false
let rewindMode = opt("--rewind") ?? "pause"
if follow {
    DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { n in
        let state = n.userInfo?["Player State"] as? String ?? "?"
        let name = n.userInfo?["Name"] as? String ?? ""
        log("playerInfo: \(state) \(name)")
        playing = state == "Playing"; lastInfo = Date()
        if !auto { if playing && needsRebuild() { rebuildPending = true }; return }
        let pid = (n.userInfo?["PersistentID"] as? NSNumber)?.int64Value
        // a notification for the same track (pause, seek) while armed/latched: the boundary moved
        if !inRoutine, pid == lastTrackID, armed || muteIn || armAt != nil {
            armed = false; armAt = nil; if muteIn { muteIn = false; log("auto: \(state) on the same track; latch released") } else { log("auto: \(state) on the same track; disarmed") }
        }
        guard playing, !inRoutine, request == nil else { return }
        var newRate: Float64? = nil
        if let id = pid, id != lastTrackID {
            lastTrackID = id
            lossyTrackAt = nil
            if let (at, rate, lossless) = decoderRates.last {
                if !lossless { lossyTrackAt = Date() }
                let dev0 = nominal(dev)
                log("auto: new track \(name): decoder rate \(rate) (seen \(String(format: "%.3f", Date().timeIntervalSince(at))) s ago), device \(dev0)")
                if rate != dev0 { newRate = rate }
            } else { log("auto: \(name): no decoder rate seen") }
        }
        if newRate != nil || needsRebuild() {
            if muteIn && newRate != nil {
                log("auto: boundary latched \(String(format: "%.0f", Double(frames - latchFrame) / nominal(dev) * 1000)) ms before Playing; keeping the old track's tail")
            } else { muteOut = true; clearDelay = true }   // a wrong-rate start may be in the delay line: drop it
            request = SwitchRequest(rate: newRate, name: name, reason: newRate != nil ? "rate \(newRate!)" : "no pipeline built while playing", tPlay: Date())
        }
    }
}
func deviceIsRunning() -> Bool { var r = UInt32(0); var a = addr(kAudioDevicePropertyDeviceIsRunning); var z = UInt32(4); return AudioObjectGetPropertyData(dev, &a, 0, nil, &z, &r) == noErr && r != 0 }
func actualRate() -> Float64 { var r: Float64 = 0; var a = addr(kAudioDevicePropertyActualSampleRate); var z = UInt32(8); AudioObjectGetPropertyData(dev, &a, 0, nil, &z, &r); return r }
/// Runs the device with silence while Music is paused (from LosslessSwitcher's TrackBoundarySwitcher).
final class SilentOutput {
    let device: AudioObjectID; var procID: AudioDeviceIOProcID?
    init?(device: AudioObjectID) { self.device = device; guard start() else { return nil } }
    func start() -> Bool {
        let st = AudioDeviceCreateIOProcIDWithBlock(&procID, device, nil) { _, _, _, out, _ in
            for b in UnsafeMutableAudioBufferListPointer(out) { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
        }
        guard st == noErr, let procID else { log("silent output: create failed \(st)"); return false }
        guard AudioDeviceStart(device, procID) == noErr else { stop(); return false }
        return true
    }
    func restart() { stop(); _ = start() }
    func stop() { guard let procID else { return }; AudioDeviceStop(device, procID); AudioDeviceDestroyIOProcID(device, procID); self.procID = nil }
}
/// Ready = running at the new nominal rate for 0.5 s with the measured clock within 0.5% (or 2 s
/// steady if the HAL never measures); from 2.5 s on, restart the keep-alive when the device has
/// been stopped for 0.25 s (at most every 1.5 s). Same constants as LosslessSwitcher.
func waitUntilReady(_ rate: Float64, timeout: Double = 8, stalled: () -> Void) -> Bool {
    let start = Date(); var runningSince: Date?, stoppedSince: Date?, measured = false
    var starts = 0, restarts = 0, lastRestart = start, wasRunning = true
    while Date().timeIntervalSince(start) < timeout {
        let running = deviceIsRunning()
        if running && !wasRunning { starts += 1 }; wasRunning = running
        stoppedSince = running ? nil : (stoppedSince ?? Date())
        if let s0 = stoppedSince, Date().timeIntervalSince(start) >= 2.5, Date().timeIntervalSince(s0) >= 0.25, Date().timeIntervalSince(lastRestart) >= 1.5 {
            restarts += 1; lastRestart = Date(); log("switch: device keeps stopping (\(starts) starts); restarting silent output"); stalled()
        }
        if nominal(dev) == rate && running {
            let since = runningSince ?? Date(); runningSince = since
            let steady = Date().timeIntervalSince(since), actual = actualRate()
            if actual > 0 {
                if actual != rate { measured = true }
                if steady >= 0.5 && ((measured && abs(actual / rate - 1) <= 0.005) || steady >= 2) {
                    if restarts > 0 || starts > 3 { log("switch: ready after \(starts) starts, \(restarts) keep-alive restarts") }
                    return true
                }
            }
        } else { runningSince = nil; measured = false }
        idle(0.01)
    }
    return false
}
func ts(_ t: Date) -> String { String(format: "%.3f", Date().timeIntervalSince(t)) }
func runSwitch(_ rq: SwitchRequest) {
    inRoutine = true; defer { inRoutine = false; rebuildPending = false }
    let t = Date(); autoSwitches += 1
    armed = false; armAt = nil
    log("switch \(autoSwitches): \(rq.name): \(rq.reason); \(muteIn ? "latched" : "output muted") at frame \(frames); pausing Music")
    _ = runScript("tell application \"Music\" to pause")
    while playing && Date().timeIntervalSince(t) < 1 { idle(0.01) }
    if muteIn {   // let the old track's tail play out of the delay line before tearing down
        let r0 = nominal(dev); let td = Date()
        while Double(frames - latchFrame) < Double(delayFrames) + 0.02 * r0 && Date().timeIntervalSince(td) < 0.5 { idle(0.005) }
    }
    muteOut = true; muteIn = false
    let pos = scriptValue("tell application \"Music\" to get player position")?.doubleValue ?? 0
    // where this play started: position now minus what played since Playing (+ ~50 ms before it)
    let played = Date().timeIntervalSince(rq.tPlay) + 0.05
    var startPos = pos - played - 0.1; if startPos < 0.5 { startPos = 0 }
    setVolume(0)
    if let old = pipe { teardown(old); pipe = nil }
    log("switch: paused after \(ts(t)) s at position \(String(format: "%.3f", pos)) (played ~\(String(format: "%.3f", played)) s) -> resume at \(String(format: "%.3f", startPos)); volume 0, torn down")
    // With Music paused nothing runs the device, and only a running device restarts at the new rate
    // and reports its clock: run it with silence until it's ready (LosslessSwitcher f71e242).
    let keepAlive = noKeepAlive ? nil : SilentOutput(device: dev)
    if let rate = rq.rate {
        let ts0 = Date()
        log("switch: set rate \(rate): \(setDeviceRate(rate))")
        var ok = true
        if noKeepAlive { idle(3.5) } else { ok = waitUntilReady(rate, stalled: { keepAlive?.restart() }) }
        log("switch: device \(ok ? "ready" : "NOT ready") at \(nominal(dev)) \(ts(ts0)) s after the set (actual \(String(format: "%.1f", actualRate())))")
    }
    idle(switchWait)
    _ = runScript("tell application \"Music\" to play")
    // hold: Music plays silently until it reports Playing and its output has been steady
    var run = musicRunning(), since = Date(); let th = Date(); var replays = 0
    while Date().timeIntervalSince(th) < 10 {
        let r = musicRunning(); if r != run { run = r; since = Date() }
        // Music gives up and pauses itself if the device doesn't come up (sw1 switch 2)
        if !playing && Date().timeIntervalSince(lastInfo) > 0.5 && replays < 3 {
            replays += 1; log("switch: Music paused itself during the hold; play again (\(replays))")
            _ = runScript("tell application \"Music\" to play")
        }
        if playing && run && Date().timeIntervalSince(since) >= settle && Date().timeIntervalSince(lastInfo) >= settle { break }
        idle(0.01)
    }
    log("switch: Music \(playing ? "playing" : "NOT playing"), output \(run ? "steady" : "not running") after \(ts(th)) s of hold; building")
    pipe = buildPipeline(); pipeBuiltAt = Date(); pipeBuiltPlaying = true; pipeRate = nominal(dev)
    keepAlive?.stop()
    if rewindMode != "pause" { setVolume(savedVolume); idle(0.15) }
    switch rewindMode {
    case "pause":
        _ = runScript("tell application \"Music\" to pause")
        let tp = Date(); while playing && Date().timeIntervalSince(tp) < 1 { idle(0.01) }
        setVolume(savedVolume)   // while paused: the muted tap and our muted output keep it silent
        _ = runScript("tell application \"Music\" to set player position to \(startPos)")
        let rate = nominal(dev); let tq = Date()
        while Double(frames - lastTapNZ) < quietSec * rate && Date().timeIntervalSince(tq) < 1 { idle(0.005) }
        log("switch: paused, rewound; tap quiet \(String(format: "%.0f", Double(frames - lastTapNZ) / rate * 1000)) ms at frame \(frames); unmuting, play")
        clearDelay = true; muteOut = false
        _ = runScript("tell application \"Music\" to play")
    case "seek":
        _ = runScript("tell application \"Music\" to set player position to \(startPos)")
        log("switch: seeked while playing; unmuting at frame \(frames)")
        clearDelay = true; muteOut = false
    default:
        log("switch: no rewind; unmuting at frame \(frames)")
        clearDelay = true; muteOut = false
    }
    runLast = musicRunning(); runSince = Date()
    log("switch \(autoSwitches) done \(ts(t)) s after the request (frame \(frames))")
}
if auto {
    savedVolume = Int(scriptValue("tell application \"Music\" to get sound volume")?.int32Value ?? 100)
    setVolume(0)
    log("auto: no pipeline until Music plays; Music volume \(savedVolume) -> 0 until then")
} else {
    pipe = buildPipeline(); pipeRate = nominal(dev)
    guard pipe != nil else { log("couldn't build the pipeline"); exit(1) }
}
var runLast = musicRunning(), runSince = Date(), pipeBuiltAt = Date(), triggers = 0
log("Music running output: \(runLast)")

var cmdDone = 0, lastFrames = 0, stalls = 0, lastTapNonZero = false
let end = Date().addingTimeInterval(seconds)
while Date() < end {
    idle(0.05)
    if frames == lastFrames { stalls += 1; if stalls == 1 { log("IO stalled at frame \(frames)") } }
    else { if stalls > 0 { log("IO resumed after ~\(stalls * 50) ms") }; stalls = 0 }
    let k = min(frames, maxFrames) - 1
    if k > 10 { let nz = tapRec[k * 2] != 0 || tapRec[k * 2 - 2] != 0 || tapRec[k * 2 - 20] != 0
        if nz != lastTapNonZero { log("tap signal \(nz ? "present" : "silent") at frame \(frames)"); lastTapNonZero = nz } }
    lastFrames = frames
    if follow {
        // poll Music's output state for 50 ms in 10 ms steps
        for _ in 0..<5 {
            let r = musicRunning()
            if r != runLast {
                log("Music output \(r ? "started" : "stopped")\(Date().timeIntervalSince(pipeBuiltAt) < 0.5 ? " (within 0.5 s of our build)" : "")")
                runLast = r; runSince = Date(); if r && needsRebuild() { rebuildPending = true }
            }
            if !auto && rebuildPending && playing && runLast && Date().timeIntervalSince(runSince) >= settle && Date().timeIntervalSince(lastInfo) >= settle {
                rebuildPending = false; triggers += 1
                let t = Date()
                if let old = pipe { teardown(old); pipe = nil }
                pipe = buildPipeline(); pipeBuiltAt = Date(); pipeBuiltPlaying = true; pipeRate = nominal(dev)
                log("trigger \(triggers): Music playing, output steady \(Int(settle * 1000)) ms at \(nominal(dev)) Hz -> rebuilt in \(String(format: "%.3f", Date().timeIntervalSince(t))) s")
                // our own teardown/build may bounce Music's output; ignore the next 0.5 s of changes
                idle(0.5); runLast = musicRunning(); runSince = Date()
            }
            idle(0.01)
        }
    }
    if auto {
        if let a = armAt, Date() >= a, !armed, !muteIn {
            armAt = nil; zeroRun = 0; armZero = Int(0.01 * nominal(dev)); armedAt = Date(); armed = true
            log("auto: boundary latch armed at frame \(frames)")
        }
        if armed && Date().timeIntervalSince(armedAt) > 5 { armed = false; log("auto: no boundary within 5 s; disarmed") }
        if muteIn && !inRoutine && request == nil && Double(frames - latchFrame) > 4 * nominal(dev) {
            muteIn = false; log("auto: latched 4 s without a track change; released")
        }
    }
    if let rq = request { request = nil; runSwitch(rq) }
    if let r = pendingUpgrade, playing, request == nil {
        pendingUpgrade = nil
        if r != nominal(dev) {
            log("auto: lossless decoder at \(r) Hz after a lossy start; switching again")
            muteOut = true; clearDelay = true
            runSwitch(SwitchRequest(rate: r, name: "(lossless upgrade)", reason: "rate \(r)", tPlay: Date()))
        }
    }
    if let cmds = try? String(contentsOfFile: "\(prefix).cmd", encoding: .utf8) {
        let lines = cmds.split(separator: "\n")
        while cmdDone < lines.count {
            let p = lines[cmdDone].split(separator: " "); cmdDone += 1
            guard p.count == 2, p[0] == "rate", let hz = Float64(p[1]) else { continue }
            let tSwitch = Date()
            if follow {
                if let old = pipe { teardown(old); pipe = nil }
                log("cmd rate \(hz): pipeline torn down; set rate: \(setDeviceRate(hz)); waiting for Music's output to restart")
                while nominal(dev) != hz && Date().timeIntervalSince(tSwitch) < 5 { idle(0.01) }
            } else if inplace {
                log("cmd rate \(hz): set in place: \(setDeviceRate(hz))")
            } else {
                if let old = pipe { teardown(old); pipe = nil }
                log("cmd rate \(hz): pipeline torn down; set rate: \(setDeviceRate(hz))")
                while nominal(dev) != hz && Date().timeIntervalSince(tSwitch) < 5 { idle(0.01) }
                log("device reports \(nominal(dev)) after \(String(format: "%.3f", Date().timeIntervalSince(tSwitch))) s; rebuilding")
                pipe = buildPipeline()
                log("rate switch total \(String(format: "%.3f", Date().timeIntervalSince(tSwitch))) s")
            }
        }
    }
}
if let p = pipe { teardown(p) }
logProc?.terminate()
if auto { setVolume(savedVolume) }
log("follow triggers: \(triggers), auto switches: \(autoSwitches)")
log("tap format notifications: \(tapFmtEvents); cycles without tap input: \(missingTap)")
log("stopped: \(cycles) cycles, \(frames) frames, \(generation) pipeline(s); device \(nominal(dev)) Hz")
let nf = min(frames, maxFrames)
for (name, p) in (tapOnly ? [("tap", tapRec)] : [("tap", tapRec), ("out", outRec), ("mon", monRec)]) {
    FileManager.default.createFile(atPath: "\(prefix).\(name).f32", contents: Data(bytes: p, count: nf * 2 * 4))
}
var cyc = ""; for i in 0..<min(cycles, maxCycles) { cyc += "\(cycSample[i]) \(cycFrames[i]) \(cycGen[i]) \(cycHost[i])\n" }
try? cyc.write(toFile: "\(prefix).cycles.txt", atomically: true, encoding: .utf8)
try? (segments.joined(separator: "\n") + "\n").write(toFile: "\(prefix).segments.txt", atomically: true, encoding: .utf8)
var peakT: Float = 0, peakM: Float = 0
for i in 0..<nf * 2 { peakT = max(peakT, abs(tapRec[i])); if !tapOnly { peakM = max(peakM, abs(monRec[i])) } }
log("wrote \(nf) frames; peak tap \(peakT), monitor \(peakM)")
