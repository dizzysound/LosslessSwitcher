// vrender <seconds> <outprefix> [--dac <name>] [--rate <hz>] [--hog] [--nonmix] [--nolock]
//         [--target <frames>] [--tau <s>] [--rec <s>] [--setdefault]
// Virtual-device renderer prototype. Music plays to "LosslessSwitcher Output" (LSOutput.driver);
// this reads it back from the device's loopback input (IOProc A), passes it through a ring to the
// DAC (IOProc B, directly on the DAC, optionally hogged with a non-mixable integer format), and
// steers the virtual device's clock (custom property 'LSrs', a rate scalar) so its sample time
// stays locked to the DAC's: no resampling, the ring's fill stays put.
// Writes <prefix>.log, <prefix>.clock.csv (every 0.5 s), <prefix>.in.f32 (what A got, 2 ch),
// <prefix>.out.f32 (what B played on ch 1-2, as float), <prefix>.cycles.txt (B's cycles:
// sample time, frames, 0, host time), <prefix>.segments.txt (for outcheck.py).
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
func array<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ t: T.Type) -> [T] {
    var a = a; var z: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &z) == noErr, z > 0 else { return [] }
    let n = Int(z) / MemoryLayout<T>.stride
    let p = UnsafeMutablePointer<T>.allocate(capacity: n); defer { p.deallocate() }
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &z, p) == noErr else { return [] }
    return Array(UnsafeBufferPointer(start: p, count: n))
}
func fmt(_ f: AudioStreamBasicDescription) -> String { "\(f.mSampleRate) Hz \(f.mChannelsPerFrame) ch \(f.mBitsPerChannel) bit flags \(f.mFormatFlags)" }
func streamFormats(_ dev: AudioObjectID, _ scope: AudioObjectPropertyScope) -> String {
    array(dev, addr(kAudioDevicePropertyStreams, scope), AudioStreamID.self).map { s -> String in
        var pf = AudioStreamBasicDescription(), vf = AudioStreamBasicDescription(); var z = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var a = addr(kAudioStreamPropertyPhysicalFormat); AudioObjectGetPropertyData(s, &a, 0, nil, &z, &pf)
        a = addr(kAudioStreamPropertyVirtualFormat); AudioObjectGetPropertyData(s, &a, 0, nil, &z, &vf)
        return "[phys \(fmt(pf)) / virt \(fmt(vf))]"
    }.joined(separator: " ")
}
func hogOwner(_ dev: AudioObjectID) -> pid_t { var h = pid_t(0); var a = addr(kAudioDevicePropertyHogMode); var z = UInt32(4); AudioObjectGetPropertyData(dev, &a, 0, nil, &z, &h); return h }
func nominal(_ dev: AudioObjectID) -> Float64 { var r: Float64 = 0; var a = addr(kAudioDevicePropertyNominalSampleRate); var z = UInt32(8); AudioObjectGetPropertyData(dev, &a, 0, nil, &z, &r); return r }
func setNominal(_ dev: AudioObjectID, _ hz: Float64) -> OSStatus { var r = hz; var a = addr(kAudioDevicePropertyNominalSampleRate); return AudioObjectSetPropertyData(dev, &a, 0, nil, 8, &r) }
func defaultOutput() -> AudioObjectID { var d = AudioObjectID(0); var a = addr(kAudioHardwarePropertyDefaultOutputDevice); var z = UInt32(4); AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &z, &d); return d }
func setDefaultOutput(_ d: AudioObjectID) -> OSStatus { var d = d; var a = addr(kAudioHardwarePropertyDefaultOutputDevice); return AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, 4, &d) }

// Turns a scope's streams off for one IOProc (so it isn't a client of them).
func streamUsageOff(_ dev: AudioObjectID, _ proc: AudioDeviceIOProcID, _ scope: AudioObjectPropertyScope) -> OSStatus {
    var a = addr(kAudioDevicePropertyIOProcStreamUsage, scope); var z: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(dev, &a, 0, nil, &z) == noErr, z > 0 else { return -1 }
    let raw = UnsafeMutableRawPointer.allocate(byteCount: Int(z), alignment: 8); defer { raw.deallocate() }
    let u = raw.assumingMemoryBound(to: AudioHardwareIOProcStreamUsage.self)
    u.pointee.mIOProc = unsafeBitCast(proc, to: UnsafeMutableRawPointer.self)
    var st = AudioObjectGetPropertyData(dev, &a, 0, nil, &z, raw)
    guard st == noErr else { return st }
    let flags = (raw + MemoryLayout<AudioHardwareIOProcStreamUsage>.offset(of: \.mStreamIsOn)!).assumingMemoryBound(to: UInt32.self)
    for i in 0..<Int(u.pointee.mNumberStreams) { flags[i] = 0 }
    st = AudioObjectSetPropertyData(dev, &a, 0, nil, z, raw)
    return st
}

let kRateScalar: AudioObjectPropertySelector = 0x4C537273 // 'LSrs'
let kStatus: AudioObjectPropertySelector = 0x4C537374     // 'LSst'
func setScalar(_ dev: AudioObjectID, _ s: Double) -> OSStatus {
    var a = addr(kRateScalar); let num: CFNumber = s as NSNumber
    var ref = Unmanaged.passUnretained(num)   // the property's data is a CFPropertyListRef
    return withExtendedLifetime(num) { AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Unmanaged<CFNumber>>.size), &ref) }
}
let kHold: AudioObjectPropertySelector = 0x4C536864       // 'LShd'
func setHold(_ dev: AudioObjectID, _ mode: Int32) -> OSStatus {
    var a = addr(kHold); let num: CFNumber = NSNumber(value: mode)
    var ref = Unmanaged.passUnretained(num)
    return withExtendedLifetime(num) { AudioObjectSetPropertyData(dev, &a, 0, nil, UInt32(MemoryLayout<Unmanaged<CFNumber>>.size), &ref) }
}
func holdState(_ dev: AudioObjectID) -> Int {
    var a = addr(kHold); var v: Unmanaged<CFPropertyList>?; var z = UInt32(MemoryLayout<CFPropertyList?>.size)
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &z, &v) == noErr, let n = v?.takeRetainedValue() as? NSNumber else { return -1 }
    return n.intValue
}
func status(_ dev: AudioObjectID) -> [String: Double] {
    var a = addr(kStatus); var v: Unmanaged<CFPropertyList>?; var z = UInt32(MemoryLayout<CFPropertyList?>.size)
    guard AudioObjectGetPropertyData(dev, &a, 0, nil, &z, &v) == noErr, let d = v?.takeRetainedValue() as? [String: Double] else { return [:] }
    return d
}

var stopRequested: sig_atomic_t = 0
func runMain() {
setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
func opt(_ name: String) -> String? { args.firstIndex(of: name).flatMap { $0 + 1 < args.count ? args[$0 + 1] : nil } }
guard args.count >= 3, let seconds = Double(args[1]) else { print("usage: vrender <seconds> <outprefix> [--dac name] [--rate hz] [--hog] [--nonmix] [--nolock] [--target frames] [--tau s] [--rec s] [--setdefault]"); exit(1) }
let prefix = args[2]
let useHog = args.contains("--hog"), nonmix = args.contains("--nonmix"), nolock = args.contains("--nolock")
let dacName = opt("--dac") ?? "MT 48"
let targetFill = Int64(opt("--target") ?? "2048")!
let tau = Double(opt("--tau") ?? "5")!
let armHold = args.contains("--armhold")
let autoMode = args.contains("--auto")   // follow Music: decoder log + playerInfo, pause/switch/rewind
// --hold "1@20:3,2@40:3": hold mode @ start second : duration seconds (experiments)
let holdPlan: [(Int32, Double, Double)] = (opt("--hold") ?? "").split(separator: ",").compactMap { e in
    let p = e.split(whereSeparator: { $0 == "@" || $0 == ":" }); guard p.count == 3, let m = Int32(p[0]), let t = Double(p[1]), let d = Double(p[2]) else { return nil }; return (m, t, d) }
FileManager.default.createFile(atPath: prefix + ".log", contents: nil)
let logFile = FileHandle(forWritingAtPath: prefix + ".log")!
let t0 = Date()
func log(_ s: String) { let l = String(format: "[%8.3f] ", Date().timeIntervalSince(t0)) + s; print(l); logFile.write((l + "\n").data(using: .utf8)!) }

var tb = mach_timebase_info_data_t(); mach_timebase_info(&tb)
let ticksPerSec = 1e9 * Double(tb.denom) / Double(tb.numer)

let devs = array(AudioObjectID(kAudioObjectSystemObject), addr(kAudioHardwarePropertyDevices), AudioObjectID.self)
guard let ls = devs.first(where: { stringProp($0, kAudioDevicePropertyDeviceUID) == "LSOutput_UID" }) else { log("LosslessSwitcher Output not found (plug-in not installed?)"); exit(1) }
guard let dac = devs.first(where: { stringProp($0, kAudioObjectPropertyName) == dacName }) else { log("no device \(dacName)"); exit(1) }
let dacOut = array(dac, addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), AudioStreamID.self)[0]
log("LS device \(ls) '\(stringProp(ls, kAudioObjectPropertyName))' @ \(nominal(ls)) Hz: out \(streamFormats(ls, kAudioObjectPropertyScopeOutput)) in \(streamFormats(ls, kAudioObjectPropertyScopeInput))")
log("DAC \(dac) '\(dacName)' @ \(nominal(dac)) Hz, hog owner \(hogOwner(dac)), default output \(defaultOutput()), my pid \(getpid())")

var restores: [() -> Void] = []
func restoreAll() { for r in restores.reversed() { r() }; restores = [] }
if args.contains("--setdefault") {
    let prev0 = defaultOutput(); let prev = prev0 == ls ? dac : prev0   // never "restore" to the virtual device
    let st = setDefaultOutput(ls)
    log("default output -> LS: \(st)")
    restores.append { log("default output restored: \(setDefaultOutput(prev))") }
}
// rates: both devices at the same nominal rate
let rate = Double(opt("--rate") ?? "\(nominal(dac))")!
if nominal(dac) != rate { log("DAC rate -> \(rate): \(setNominal(dac, rate))") }
if nominal(ls) != rate { log("LS rate -> \(rate): \(setNominal(ls, rate))") }
for _ in 0..<50 where nominal(ls) != rate || nominal(dac) != rate { Thread.sleep(forTimeInterval: 0.05) }
log("rates: LS \(nominal(ls)), DAC \(nominal(dac))")
log("reset LS scalar: \(setScalar(ls, 1.0)); status \(status(ls))")
restores.append { log("LS scalar reset: \(setScalar(ls, 1.0))") }

if useHog {
    var me = getpid(); var a = addr(kAudioDevicePropertyHogMode)
    let st = AudioObjectSetPropertyData(dac, &a, 0, nil, 4, &me)
    log("hog DAC: \(st), owner \(hogOwner(dac))")
    restores.append { var none = pid_t(-1); var a = addr(kAudioDevicePropertyHogMode)
        log("released hog: \(AudioObjectSetPropertyData(dac, &a, 0, nil, 4, &none)), owner \(hogOwner(dac))") }
}
if nonmix {
    var pf = AudioStreamBasicDescription(); var z = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var a = addr(kAudioStreamPropertyPhysicalFormat); AudioObjectGetPropertyData(dacOut, &a, 0, nil, &z, &pf)
    pf.mFormatFlags |= kAudioFormatFlagIsNonMixable
    let st = AudioObjectSetPropertyData(dacOut, &a, 0, nil, z, &pf)
    Thread.sleep(forTimeInterval: 0.3)
    log("DAC non-mixable: \(st) -> \(streamFormats(dac, kAudioObjectPropertyScopeOutput))")
    // restore the mixable twin of the current format (never a saved struct: it carries a rate)
    restores.append { var o = AudioStreamBasicDescription(); var z = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var a = addr(kAudioStreamPropertyPhysicalFormat); AudioObjectGetPropertyData(dacOut, &a, 0, nil, &z, &o)
        o.mFormatFlags &= ~kAudioFormatFlagIsNonMixable
        log("restored mixable: \(AudioObjectSetPropertyData(dacOut, &a, 0, nil, z, &o))") }
}
for sig in [SIGINT, SIGTERM] { signal(sig) { _ in stopRequested = 1 } }

// shared state
func newRing() -> UnsafeMutablePointer<vr_ring> { let r = UnsafeMutablePointer<vr_ring>.allocate(capacity: 1); memset(r, 0, MemoryLayout<vr_ring>.size); return r }
func newI64(_ v: Int64) -> UnsafeMutablePointer<vr_i64> { let a = UnsafeMutablePointer<vr_i64>.allocate(capacity: 1); memset(a, 0, 8); vr_set(a, v); return a }
let ring = newRing()                       // A -> B
let recInRing = newRing(), recOutRing = newRing()   // recordings, drained to disk by the writer
let stampA = UnsafeMutablePointer<vr_stamp>.allocate(capacity: 1); memset(stampA, 0, MemoryLayout<vr_stamp>.size)
let stampB = UnsafeMutablePointer<vr_stamp>.allocate(capacity: 1); memset(stampB, 0, MemoryLayout<vr_stamp>.size)
// rate boundaries: A marks the ring position where the virtual device's time line restarted (its
// rate changed); B plays up to it, then waits (zeros) until the control thread has switched the DAC.
let marker = newI64(-1)          // ring position of a pending boundary, -1 none
let atBoundary = newI64(0)       // B reached the marker
let resume = newI64(0)           // control -> B: go on past the marker
let inFrames = newI64(0), outFrames = newI64(0)
let maxCycles = Int((seconds + 5) * 192000 / 64)
let cyclesA = UnsafeMutablePointer<Double>.allocate(capacity: maxCycles * 3); var nCyclesA = 0
let cyclesB = UnsafeMutablePointer<Double>.allocate(capacity: maxCycles * 3); var nCyclesB = 0
var segIn: [(Int64, Double)] = [(0, rate)], segOut: [(Int64, Double)] = [(0, rate)]
let scratch = UnsafeMutablePointer<Float>.allocate(capacity: 16384 * 2)
var playing = false
var intOut = false
var aCycles = 0, bCycles = 0
var lastASample = -1.0
let latchZeros = newI64(0)   // > 0: latch armed, zero-run length in frames
var zeroRun = 0
var outSegmentAt: Int64 = -1

// A: the virtual device's loopback input -> ring
var procA: AudioDeviceIOProcID?
var st = AudioDeviceCreateIOProcIDWithBlock(&procA, ls, nil) { _, inInput, inInputTime, _, _ in
    let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
    guard let b = ins.first, let d = b.mData else { return }
    let n = Int(b.mDataByteSize) / 8
    let f = d.assumingMemoryBound(to: Float.self)
    let t = inInputTime.pointee
    if !armHold && !autoMode && lastASample >= 0 && t.mSampleTime < lastASample { vr_set(marker, vr_written(ring)) }   // time line restarted
    lastASample = t.mSampleTime
    // boundary latch (--auto): armed shortly before a track end whose successor needs another rate;
    // the first run of latchZeros exact-zero frames marks the ring there (Music's inter-track zeros)
    let lz = vr_get(latchZeros)
    if lz > 0 && vr_get(marker) < 0 {
        let w0 = vr_written(ring)
        for i in 0..<n {
            if f[i * 2] == 0 && f[i * 2 + 1] == 0 { zeroRun += 1 } else { zeroRun = 0 }
            if zeroRun >= lz { vr_set(marker, w0 + Int64(i) + 1); vr_set(latchZeros, 0); zeroRun = 0; break }
        }
    } else { zeroRun = 0 }
    vr_write(ring, f, Int64(n))
    vr_write(recInRing, f, Int64(n))
    vr_stamp_put(stampA, t.mSampleTime + Double(n), Double(t.mHostTime), t.mRateScalar) // end of this buffer
    if nCyclesA < maxCycles { cyclesA[nCyclesA * 3] = t.mSampleTime; cyclesA[nCyclesA * 3 + 1] = Double(n); cyclesA[nCyclesA * 3 + 2] = Double(t.mHostTime); nCyclesA += 1 }
    vr_set(inFrames, vr_get(inFrames) + Int64(n))
    aCycles += 1
}
guard st == noErr, let procA else { log("IOProc A: \(st)"); restoreAll(); exit(1) }
// A is an input-only client of the virtual device
log("A: output stream usage off: \(streamUsageOff(ls, procA, kAudioObjectPropertyScopeOutput))")

// B: ring -> DAC ch 1-2
var procB: AudioDeviceIOProcID?
st = AudioDeviceCreateIOProcIDWithBlock(&procB, dac, nil) { _, _, _, outOutput, inOutputTime in
    let outs = UnsafeMutableAudioBufferListPointer(outOutput)
    guard let ob = outs.first, let od = ob.mData else { return }
    let ch = Int(ob.mNumberChannels), n = Int(ob.mDataByteSize) / 4 / ch
    let t = inOutputTime.pointee
    vr_stamp_put(stampB, t.mSampleTime, Double(t.mHostTime), t.mRateScalar)
    if vr_get(resume) != 0 {   // the DAC runs at the new rate: go on past the marker
        vr_set(marker, -1); vr_set(atBoundary, 0); vr_set(resume, 0)
        outSegmentAt = vr_get(outFrames)
        if armHold || autoMode { playing = false }   // Music restarts: wait for the target fill again
        if autoMode { vr_trim(ring, 0) }             // drop the wrong-rate start and the pause fade
    }
    let m = vr_get(marker)
    if !playing && vr_fill(ring) >= targetFill { vr_trim(ring, targetFill); playing = true }   // startup backlog is silence
    if playing {
        vr_read_upto(ring, scratch, Int64(n), m)
        if m >= 0 && vr_readpos(ring) >= m { vr_set(atBoundary, 1) }
    } else { scratch.update(repeating: 0, count: n * 2) }
    if intOut {
        let o = od.assumingMemoryBound(to: Int32.self)
        for f in 0..<n { for c in 0..<ch { o[f * ch + c] = c < 2 ? Int32(clamping: Int64((Double(scratch[f * 2 + c]) * 2147483648.0).rounded())) : 0 } }
    } else {
        let o = od.assumingMemoryBound(to: Float.self)
        for f in 0..<n { for c in 0..<ch { o[f * ch + c] = c < 2 ? scratch[f * 2 + c] : 0 } }
    }
    vr_write(recOutRing, scratch, Int64(n))
    if nCyclesB < maxCycles { cyclesB[nCyclesB * 3] = t.mSampleTime; cyclesB[nCyclesB * 3 + 1] = Double(n); cyclesB[nCyclesB * 3 + 2] = Double(t.mHostTime); nCyclesB += 1 }
    vr_set(outFrames, vr_get(outFrames) + Int64(n))
    bCycles += 1
}
guard st == noErr, let procB else { log("IOProc B: \(st)"); restoreAll(); exit(1) }
log("B: DAC input stream usage off: \(streamUsageOff(dac, procB, kAudioObjectPropertyScopeInput))")
func dacIsInt() -> Bool {
    var vf = AudioStreamBasicDescription(); var z = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var a = addr(kAudioStreamPropertyVirtualFormat); AudioObjectGetPropertyData(dacOut, &a, 0, nil, &z, &vf)
    return vf.mFormatFlags & kAudioFormatFlagIsFloat == 0
}
intOut = dacIsInt()
log("B: DAC output \(intOut ? "int32" : "float32")")

// recordings stream to disk
for ext in ["in.f32", "out.f32"] { FileManager.default.createFile(atPath: prefix + "." + ext, contents: nil) }
let fIn = FileHandle(forWritingAtPath: prefix + ".in.f32")!, fOut = FileHandle(forWritingAtPath: prefix + ".out.f32")!
let drainBuf = UnsafeMutablePointer<Float>.allocate(capacity: (1 << 20) * 2)
func drainRecordings() {
    for (r, f) in [(recInRing, fIn), (recOutRing, fOut)] {
        let n = vr_drain(r, drainBuf, 1 << 20)
        if n > 0 { f.write(Data(bytes: drainBuf, count: Int(n) * 8)) }
    }
}

if armHold { log("arm hold: \(setHold(ls, 3)), state \(holdState(ls))"); restores.append { log("hold released: \(setHold(ls, 0))") } }
log("start A: \(AudioDeviceStart(ls, procA))")
log("start B: \(AudioDeviceStart(dac, procB))")
FileManager.default.createFile(atPath: prefix + ".clock.csv", contents: "t,fill,phase,err,dacScalarHAL,lsScalarHAL,lsScalarSet,overruns,underruns,aCycles,bCycles,rate\n".data(using: .utf8))
let csv = FileHandle(forWritingAtPath: prefix + ".clock.csv")!; csv.seekToEndOfFile()

// ---- --auto: Music's decoder log + playerInfo -> boundary latch + pause/switch/rewind
let evLock = NSLock()
var decoderEvents: [(Date, Double, Bool)] = []   // (arrival, rate, lossless)
var infoEvents: [(Date, String, Int64?, String)] = []   // (arrival, state, persistent ID, name)
func runScript(_ src: String) -> NSAppleEventDescriptor? {
    DispatchQueue.main.sync {
        var err: NSDictionary?; let d = NSAppleScript(source: src)?.executeAndReturnError(&err)
        if let err { log("AppleScript error: \(err)") }; return err == nil ? d : nil
    }
}
var logProc: Process?
if autoMode {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/log")
    p.arguments = ["stream", "--style", "compact", "--predicate", "process == \"Music\" AND eventMessage CONTAINS \"Input format:\""]
    let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
    var partial = ""
    out.fileHandleForReading.readabilityHandler = { h in
        guard let chunk = String(data: h.availableData, encoding: .utf8), !chunk.isEmpty else { return }
        partial += chunk
        var lines = partial.components(separatedBy: "\n"); partial = lines.removeLast()
        for line in lines {
            guard let r = line.range(of: "Input format:"), let hz = line[r.upperBound...].range(of: #"[0-9]+ Hz"#, options: .regularExpression) else { continue }
            let rate = Double(line[r.upperBound...][hz].dropLast(3))!
            evLock.lock(); decoderEvents.append((Date(), rate, line.contains("lac"))); evLock.unlock()
        }
    }
    try? p.run(); logProc = p
    restores.append { logProc?.terminate() }
    DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: nil) { n in
        let state = n.userInfo?["Player State"] as? String ?? "?"
        let pid = (n.userInfo?["PersistentID"] as? NSNumber)?.int64Value
        evLock.lock(); infoEvents.append((Date(), state, pid, n.userInfo?["Name"] as? String ?? "")); evLock.unlock()
    }
    log("auto: watching Music's decoder log and playerInfo")
}
var lastDecoderRate: Double?, lastTrackID: Int64?, armAt: Date?, latchedAt: Date?, autoSwitches = 0, musicPlaying = false
func waitFor(_ timeout: Double, _ cond: () -> Bool) -> Bool {
    let t = Date(); while !cond() { if Date().timeIntervalSince(t) > timeout { return false }; Thread.sleep(forTimeInterval: 0.005); drainRecordings() }; return true
}
/// The DAC runs (B keeps it busy with silence at the boundary); ready = new nominal rate, B cycling,
/// HAL rate scalar within 0.5%, for 150 ms.
func waitDacReady(_ r: Double, timeout: Double = 10) -> Bool {
    var since: Date?; var lastC = bCycles; let t = Date()
    while Date().timeIntervalSince(t) < timeout {
        Thread.sleep(forTimeInterval: 0.01); drainRecordings()
        var sB = 0.0, hB = 0.0, rB = 0.0; _ = vr_stamp_get(stampB, &sB, &hB, &rB)
        let ok = nominal(dac) == r && bCycles > lastC && abs(rB - 1) < 0.005; lastC = bCycles
        if ok { since = since ?? Date(); if Date().timeIntervalSince(since!) >= 0.15 { return true } } else { since = nil }
    }
    return false
}
func autoSwitch(to r: Double, name: String, tPlay: Date) {
    autoSwitches += 1; let t = Date()
    _ = runScript("tell application \"Music\" to pause")
    let latched = vr_get(marker) >= 0
    if !latched { vr_set(atBoundary, 0); vr_set(marker, vr_readpos(ring)) }   // no latch: cut now (a wrong-rate start may have played)
    vr_set(latchZeros, 0); armAt = nil; latchedAt = nil
    let reached = waitFor(1) { vr_get(atBoundary) != 0 }
    log("switch \(autoSwitches): \(name) needs \(Int(r)) Hz (DAC \(Int(curRate))); \(latched ? "latched at the old track's end" : "NOT latched: cut at the play position"); paused; boundary \(reached ? "reached" : "NOT reached") \(ts(t)) s")
    let tl = Date(); log("  LS -> \(Int(r)): \(setNominal(ls, r))"); _ = waitFor(2) { nominal(ls) == r }
    log("  LS at \(nominal(ls)) after \(ts(tl)) s; DAC -> \(Int(r)): \(setNominal(dac, r))")
    let td = Date(); let ready = waitDacReady(r)
    intOut = dacIsInt()
    log("  DAC \(ready ? "ready" : "NOT ready") after \(ts(td)) s; \(streamFormats(dac, kAudioObjectPropertyScopeOutput))")
    segOut.append((vr_get(outFrames), r))
    vr_set(resume, 1); _ = waitFor(1) { vr_get(resume) == 0 }
    segIn.append((vr_written(ring), r))
    curRate = r; phase0 = nil; integ = 0; dacScalarEst = 0
    let pos = runScript("tell application \"Music\" to get player position")?.doubleValue ?? 0
    let played = Date().timeIntervalSince(tPlay) + 0.05
    var startPos = pos - played - 0.1; if startPos < 0.5 { startPos = 0 }
    _ = runScript("tell application \"Music\" to set player position to \(startPos)")
    _ = runScript("tell application \"Music\" to play")
    log("  rewound to \(String(format: "%.3f", startPos)) (was \(String(format: "%.3f", pos)), played ~\(String(format: "%.3f", played)) s), play; switch \(ts(t)) s after the request")
}
func autoTick() {
    evLock.lock(); let dec = decoderEvents, info = infoEvents; decoderEvents = []; infoEvents = []; evLock.unlock()
    for (_, r, lossless) in dec {
        if r != lastDecoderRate { log("decoder: \(Int(r)) Hz \(lossless ? "lossless" : "lossy")") }
        lastDecoderRate = r
        // another rate pre-rolled while playing: the next track -> arm the latch near the current end
        if musicPlaying && r != curRate && armAt == nil && latchedAt == nil && vr_get(latchZeros) == 0 {
            let pos = runScript("tell application \"Music\" to get player position")?.doubleValue ?? 0
            let dur = runScript("tell application \"Music\" to get duration of current track")?.doubleValue ?? 0
            armAt = Date().addingTimeInterval(max(0, dur - pos - 1.5))
            log("auto: next track needs \(Int(r)) Hz; \(String(format: "%.2f", dur - pos)) s left; latch armed in \(String(format: "%.2f", max(0, dur - pos - 1.5))) s")
        }
    }
    for (tInfo, state, pid, name) in info {
        musicPlaying = state == "Playing"
        if pid == lastTrackID {   // pause/seek on the same track: the boundary moved
            if armAt != nil || vr_get(latchZeros) > 0 { armAt = nil; vr_set(latchZeros, 0); log("auto: \(state) on the same track; disarmed") }
            continue
        }
        guard state == "Playing" else { continue }
        lastTrackID = pid
        let r = lastDecoderRate ?? curRate
        log("auto: new track \(name): decoder \(Int(r)) Hz, current \(Int(curRate)) Hz")
        if r != curRate { autoSwitch(to: r, name: name, tPlay: tInfo) }
        else if latchedAt != nil { vr_set(marker, -1); vr_set(atBoundary, 0); latchedAt = nil; log("auto: same rate after all; latch released") }
    }
    if let a = armAt, Date() >= a { armAt = nil; vr_set(latchZeros, Int64(0.01 * curRate)); log("auto: latch armed (10 ms of zeros) at in frame \(vr_written(ring))") }
    if vr_get(marker) >= 0 && latchedAt == nil { latchedAt = Date(); log("auto: latched at ring \(vr_get(marker)) (fill \(vr_fill(ring)))") }
    if let l = latchedAt, Date().timeIntervalSince(l) > 4 { vr_set(marker, -1); vr_set(atBoundary, 0); latchedAt = nil; log("auto: latched 4 s without a new track; released") }
}

// control loop: 50 ms ticks; the PLL runs every 0.5 s while no switch is in progress
let tick = 0.05, dt = 0.5
var phase0: Double?
var dacScalarEst = 0.0, integ = 0.0, lsScalar = 1.0
var curRate = rate
let end = Date().addingTimeInterval(seconds)
var lastLog = Date.distantPast, lastPLL = Date()
var holdsStarted = Set<Int>(), holdsDone = Set<Int>()
var switchT0: Date?, dacSetAt: Date?, newRate = 0.0, steadySince: Date?, lastBC = 0
func ts(_ t: Date?) -> String { t.map { String(format: "%.3f", Date().timeIntervalSince($0)) } ?? "-" }
while Date() < end && stopRequested == 0 {
    Thread.sleep(forTimeInterval: tick)
    drainRecordings()
    if autoMode { autoTick() }
    // --- scheduled holds (experiment)
    let tRun = Date().timeIntervalSince(t0)
    for (k, h) in holdPlan.enumerated() where !holdsDone.contains(k) {
        if !holdsStarted.contains(k) && tRun >= h.1 { holdsStarted.insert(k); log("hold mode \(h.0) on: \(setHold(ls, h.0)); state \(holdState(ls)); LS status \(status(ls)["sampleNow"] ?? -1)") }
        if holdsStarted.contains(k) && tRun >= h.1 + h.2 { holdsDone.insert(k); log("hold off: \(setHold(ls, 0)); state \(holdState(ls)); status \(status(ls))") }
    }
    // --- arm-hold: the virtual device's rate changed and its IO is stopped; everything in the ring is old-rate
    if armHold && switchT0 == nil && nominal(ls) != curRate {
        vr_set(marker, vr_written(ring))
    }
    // --- rate switch state machine
    if !autoMode && switchT0 == nil && vr_get(marker) >= 0 {
        switchT0 = Date(); newRate = nominal(ls)
        segIn.append((vr_get(marker), newRate))
        log("boundary: LS time line restarted at ring \(vr_get(marker)); LS now \(newRate) Hz (DAC \(curRate)); fill \(vr_fill(ring))")
    }
    if let sw = switchT0 {
        if dacSetAt == nil && vr_get(atBoundary) != 0 {
            log("B reached the boundary after \(ts(sw)) s")
            if nominal(dac) != newRate { log("DAC -> \(newRate): \(setNominal(dac, newRate))") }
            dacSetAt = Date(); steadySince = nil; lastBC = bCycles
        }
        if let ds = dacSetAt {
            // ready: DAC nominal == new rate, B cycling, HAL rate scalar sane, for 150 ms
            var sB = 0.0, hB = 0.0, rB = 0.0; _ = vr_stamp_get(stampB, &sB, &hB, &rB)
            let ok = nominal(dac) == newRate && bCycles > lastBC && abs(rB - 1) < 0.005
            lastBC = bCycles
            if ok { if steadySince == nil { steadySince = Date() } } else { steadySince = nil }
            if let ss = steadySince, Date().timeIntervalSince(ss) >= 0.15 {
                intOut = dacIsInt()
                segOut.append((vr_get(outFrames), newRate))   // approximate; B's exact point is outSegmentAt
                vr_set(resume, 1)
                if armHold {
                    log("release hold: \(setHold(ls, 0))")
                    for _ in 0..<100 where holdState(ls) != 0 { Thread.sleep(forTimeInterval: 0.01) }
                    log("re-arm: \(setHold(ls, 3)), state \(holdState(ls))")
                }
                log("DAC ready at \(newRate) after \(ts(ds)) s (switch total \(ts(sw)) s); resuming, fill \(vr_fill(ring)) (\(String(format: "%.2f", Double(vr_fill(ring)) / newRate)) s); DAC \(streamFormats(dac, kAudioObjectPropertyScopeOutput))")
                curRate = newRate; phase0 = nil; integ = 0; dacScalarEst = 0
                switchT0 = nil; dacSetAt = nil
            } else if Date().timeIntervalSince(ds) > 10 { log("DAC not ready after 10 s"); stopRequested = 1 }
        }
        if outSegmentAt >= 0 { segOut[segOut.count - 1].0 = outSegmentAt; outSegmentAt = -1 }
        continue
    }
    if outSegmentAt >= 0 { segOut[segOut.count - 1].0 = outSegmentAt; outSegmentAt = -1 }
    guard Date().timeIntervalSince(lastPLL) >= dt else { continue }
    lastPLL = Date()
    var sA = 0.0, hA = 0.0, rA = 0.0, sB = 0.0, hB = 0.0, rB = 0.0
    guard vr_stamp_get(stampA, &sA, &hA, &rA) != 0, vr_stamp_get(stampB, &sB, &hB, &rB) != 0 else {
        log("waiting for IO: A \(aCycles) cycles, B \(bCycles) cycles"); continue
    }
    let tpf = ticksPerSec / curRate
    let h = Double(mach_absolute_time())
    let vNow = sA + (h - hA) / (tpf * lsScalar)
    let dNow = sB + (h - hB) / (tpf * rB)
    let phase = vNow - dNow
    dacScalarEst = dacScalarEst == 0 ? rB : dacScalarEst + 0.1 * (rB - dacScalarEst)
    var err = 0.0
    if playing {
        if phase0 == nil { phase0 = phase; log("locking: fill \(vr_fill(ring)), phase0 \(String(format: "%.1f", phase))") }
        err = phase - phase0!
        if !nolock {
            // P + I on the phase error; err > 0: the virtual device runs ahead -> slow it down
            let kp = 1 / (tau * curRate)
            integ += kp * err * dt / (4 * tau)
            integ = max(-300e-6, min(300e-6, integ))
            let corr = max(-300e-6, min(300e-6, kp * err + integ))
            let s = dacScalarEst * (1 + corr)
            let r = setScalar(ls, s)
            if r == noErr { lsScalar = s } else { log("set scalar failed: \(r)") }
        }
    }
    let line = String(format: "%.2f,%lld,%.2f,%.3f,%.9f,%.9f,%.9f,%lld,%lld,%d,%d,%.0f", Date().timeIntervalSince(t0), vr_fill(ring), phase, err, rB, rA, lsScalar, vr_overruns(ring), vr_underruns(ring), aCycles, bCycles, curRate)
    csv.write((line + "\n").data(using: .utf8)!)
    if Date().timeIntervalSince(lastLog) >= 10 { lastLog = Date(); log("\(Int(curRate)) Hz fill \(vr_fill(ring)) err \(String(format: "%.2f", err)) dacHAL \(String(format: "%.9f", rB)) lsSet \(String(format: "%.9f", lsScalar)) over \(vr_overruns(ring)) under \(vr_underruns(ring))") }
}
log("stopping (\(stopRequested != 0 ? "signal" : "time"))")
AudioDeviceStop(dac, procB); AudioDeviceStop(ls, procA)
AudioDeviceDestroyIOProcID(dac, procB); AudioDeviceDestroyIOProcID(ls, procA)
drainRecordings()
log("LS status at end: \(status(ls))")
restoreAll()
func writeCycles(_ c: UnsafeMutablePointer<Double>, _ n: Int, _ path: String) {
    var ct = ""; for i in 0..<n { ct += String(format: "%.0f %.0f 0 %.0f\n", c[i * 3], c[i * 3 + 1], c[i * 3 + 2]) }
    FileManager.default.createFile(atPath: path, contents: ct.data(using: .utf8))
}
writeCycles(cyclesB, nCyclesB, prefix + ".cycles.txt")
writeCycles(cyclesA, nCyclesA, prefix + ".in.cycles.txt")
FileManager.default.createFile(atPath: prefix + ".segments.txt", contents: segOut.map { "\($0.0) \($0.1)" }.joined(separator: "\n").appending("\n").data(using: .utf8))
FileManager.default.createFile(atPath: prefix + ".in.segments.txt", contents: segIn.map { "\($0.0) \($0.1)" }.joined(separator: "\n").appending("\n").data(using: .utf8))
log("wrote \(vr_get(inFrames)) in / \(vr_get(outFrames)) out frames; over \(vr_overruns(ring)) under \(vr_underruns(ring)); recording overruns in \(vr_overruns(recInRing)) out \(vr_overruns(recOutRing))")
log("segments in: \(segIn)  out: \(segOut)")
exit(0)
}

NSApplication.shared.setActivationPolicy(.regular)
Thread.detachNewThread { runMain() }
NSApplication.shared.run()
