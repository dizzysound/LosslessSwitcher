// devtest <device> <seconds> <outprefix> [--hog] [--nonmix] [--direct] [--rateswitch <hz>@<sec>]
// Device-side renderer experiments that need no audio-capture permission: plays a quiet
// deterministic noise signal (-40 dBFS, 24-bit-quantized, L and R different) on channels 1-2 of
// the device, through a private aggregate whose main/clock device is that device (or directly with
// --direct), and records the device's inputs at the same time to look for a digital loopback.
// Writes <prefix>.sent.f32 (2 ch) and <prefix>.in.f32 (device input channels), both float32
// interleaved, one row per frame, aligned to the same IO cycles.
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
        return "[\(s) phys \(fmt(pf)) / virt \(fmt(vf))]"
    }.joined(separator: " ")
}
func hogOwner(_ dev: AudioObjectID) -> pid_t { var h = pid_t(0); var a = addr(kAudioDevicePropertyHogMode); var z = UInt32(4); AudioObjectGetPropertyData(dev, &a, 0, nil, &z, &h); return h }
func nominal(_ dev: AudioObjectID) -> Float64 { var r: Float64 = 0; var a = addr(kAudioDevicePropertyNominalSampleRate); var z = UInt32(8); AudioObjectGetPropertyData(dev, &a, 0, nil, &z, &r); return r }
let t0 = Date()
func log(_ s: String) { print(String(format: "[%7.3f] ", Date().timeIntervalSince(t0)) + s) }

setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard args.count >= 4, let seconds = Double(args[2]) else { print("usage: devtest <device> <seconds> <outprefix> [--hog] [--nonmix] [--direct] [--rateswitch hz@sec]"); exit(1) }
let useHog = args.contains("--hog"), nonmix = args.contains("--nonmix"), direct = args.contains("--direct")
var rateSwitch: (Float64, Double)?
if let i = args.firstIndex(of: "--rateswitch"), i + 1 < args.count {
    let p = args[i + 1].split(separator: "@"); rateSwitch = (Float64(p[0])!, Double(p[1])!)
}
let devs = array(AudioObjectID(kAudioObjectSystemObject), addr(kAudioHardwarePropertyDevices), AudioObjectID.self)
guard let dev = devs.first(where: { stringProp($0, kAudioObjectPropertyName) == args[1] }) else { print("no device"); exit(1) }
let uid = stringProp(dev, kAudioDevicePropertyDeviceUID)
let outStream = array(dev, addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), AudioStreamID.self)[0]
log("device \(dev) @ \(nominal(dev)) Hz, hog owner \(hogOwner(dev)), my pid \(getpid())")

var restore: (() -> Void)?
if useHog {
    var me = getpid(); var a = addr(kAudioDevicePropertyHogMode)
    let st = AudioObjectSetPropertyData(dev, &a, 0, nil, 4, &me)
    log("set hog mode: status \(st), owner now \(hogOwner(dev))")
}
if nonmix {
    var pf = AudioStreamBasicDescription(); var z = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var a = addr(kAudioStreamPropertyPhysicalFormat); AudioObjectGetPropertyData(outStream, &a, 0, nil, &z, &pf)
    let old = pf
    pf.mFormatFlags |= kAudioFormatFlagIsNonMixable
    let st = AudioObjectSetPropertyData(outStream, &a, 0, nil, z, &pf)
    Thread.sleep(forTimeInterval: 0.3)
    log("set non-mixable physical format: status \(st) -> \(streamFormats(dev, kAudioObjectPropertyScopeOutput))")
    _ = old
    // restore the mixable twin of whatever the format is now (the rate may have changed meanwhile)
    restore = { var o = AudioStreamBasicDescription(); var z = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var a = addr(kAudioStreamPropertyPhysicalFormat); AudioObjectGetPropertyData(outStream, &a, 0, nil, &z, &o)
        o.mFormatFlags &= ~kAudioFormatFlagIsNonMixable
        let st = AudioObjectSetPropertyData(outStream, &a, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &o)
        log("restored mixable physical format: status \(st)") }
}

if args.contains("--in16") {
    let inStream = array(dev, addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeInput), AudioStreamID.self)[0]
    var pf = AudioStreamBasicDescription(); var z = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var a = addr(kAudioStreamPropertyPhysicalFormat); AudioObjectGetPropertyData(inStream, &a, 0, nil, &z, &pf)
    let old = pf
    pf.mChannelsPerFrame = 16; pf.mBytesPerFrame = 64; pf.mBytesPerPacket = 64
    let st = AudioObjectSetPropertyData(inStream, &a, 0, nil, z, &pf)
    Thread.sleep(forTimeInterval: 0.5)
    log("set 16-ch input format: status \(st) -> \(streamFormats(dev, kAudioObjectPropertyScopeInput))")
    let prev = restore
    restore = { prev?(); var o = old; var a = addr(kAudioStreamPropertyPhysicalFormat)
        let st = AudioObjectSetPropertyData(inStream, &a, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &o)
        Thread.sleep(forTimeInterval: 0.5)
        log("restored input format: status \(st) -> \(streamFormats(dev, kAudioObjectPropertyScopeInput))") }
}
var io = dev
var agg = AudioObjectID(0)
if !direct {
    let aggDesc: [String: Any] = [
        kAudioAggregateDeviceUIDKey: UUID().uuidString, kAudioAggregateDeviceNameKey: "devtest",
        kAudioAggregateDeviceIsPrivateKey: 1, kAudioAggregateDeviceMainSubDeviceKey: uid,
        kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: uid]],
    ]
    let st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
    guard st == noErr else { log("create aggregate failed \(st)"); restore?(); exit(1) }
    io = agg
    Thread.sleep(forTimeInterval: 0.2)
    log("aggregate \(agg) @ \(nominal(agg)) Hz, hog owner (sub) \(hogOwner(dev)), (agg) \(hogOwner(agg))")
}
log("io device output: \(streamFormats(io, kAudioObjectPropertyScopeOutput))")
log("io device input:  \(streamFormats(io, kAudioObjectPropertyScopeInput))")

// deterministic noise: xorshift, 24-bit quantized, -40 dBFS peak
var rng: UInt64 = 0x9E3779B97F4A7C15
func noise() -> Float { rng ^= rng << 13; rng ^= rng >> 7; rng ^= rng << 17
    let v = Int32(truncatingIfNeeded: rng >> 40) - (1 << 23)  // uniform 24-bit
    return Float(v / 100) / Float(1 << 23) }                   // ~ -40 dBFS, exactly representable
let maxFrames = Int((seconds + 2) * 200000)
let sent = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * 2)
let inCh = 16
let rec = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * inCh); rec.initialize(repeating: 0, count: maxFrames * inCh)
var frames = 0, cycles = 0, shapes = "", intOut = 0, gapLog: [String] = []
var lastHost: UInt64 = 0
var procID: AudioDeviceIOProcID?
var st = AudioDeviceCreateIOProcIDWithBlock(&procID, io, nil) { _, inInput, inTime, outOutput, _ in
    let ins = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
    let outs = UnsafeMutableAudioBufferListPointer(outOutput)
    cycles += 1
    if shapes.isEmpty { shapes = "in " + ins.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: ",") + " out " + outs.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: ",") }
    guard let ob = outs.first, let od = ob.mData else { return }
    let och = Int(ob.mNumberChannels)
    let n = Int(ob.mDataByteSize) / 4 / och
    // non-mixable streams hand the IOProc the physical (integer) format
    let isInt = nonmix && intOut == 1
    for f in 0..<n {
        let l = noise(), r = noise()
        if frames + f < maxFrames { sent[(frames + f) * 2] = l; sent[(frames + f) * 2 + 1] = r }
        for c in 0..<och {
            let v: Float = c == 0 ? l : (c == 1 ? r : 0)
            if isInt { od.assumingMemoryBound(to: Int32.self)[f * och + c] = Int32(Double(v) * 2147483648.0) }
            else { od.assumingMemoryBound(to: Float.self)[f * och + c] = v }
        }
    }
    if let ib = ins.first, let id = ib.mData {
        let ich = Int(ib.mNumberChannels); let m = min(n, Int(ib.mDataByteSize) / 4 / ich)
        for f in 0..<m where frames + f < maxFrames { for c in 0..<min(ich, inCh) {
            rec[(frames + f) * inCh + c] = false ? 0
                                                 : id.assumingMemoryBound(to: Float.self)[f * ich + c] } }
    }
    frames += n
}
guard st == noErr, let procID else { log("IOProc failed \(st)"); exit(1) }
// learn whether the IO device's output virtual format is integer
do {
    let s = array(io, addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), AudioStreamID.self)
    if let s0 = s.first { var vf = AudioStreamBasicDescription(); var z = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var a = addr(kAudioStreamPropertyVirtualFormat); AudioObjectGetPropertyData(s0, &a, 0, nil, &z, &vf)
        intOut = vf.mFormatFlags & kAudioFormatFlagIsFloat == 0 ? 1 : 0 }
}
log("output virtual format is \(intOut == 1 ? "integer" : "float")")
let tStart = Date()
st = AudioDeviceStart(io, procID)
log("AudioDeviceStart: \(st)")
// wait for the first cycle
while cycles == 0 && Date().timeIntervalSince(tStart) < 10 { Thread.sleep(forTimeInterval: 0.005) }
log("first IO cycle after \(String(format: "%.3f", Date().timeIntervalSince(tStart))) s; \(shapes)")
var switched = false, lastFrames = 0, stalls = 0
let end = Date().addingTimeInterval(seconds)
while Date() < end {
    Thread.sleep(forTimeInterval: 0.05)
    if let (hz, at) = rateSwitch, !switched, Date().timeIntervalSince(tStart) >= at {
        var r = hz; var a = addr(kAudioDevicePropertyNominalSampleRate)
        let s1 = AudioObjectSetPropertyData(dev, &a, 0, nil, 8, &r)
        log("set device rate \(hz): status \(s1)"); switched = true
    }
    if frames == lastFrames { stalls += 1; if stalls == 1 { log("IO stalled at frame \(frames)") } }
    else { if stalls > 0 { log("IO resumed after \(stalls * 50) ms stall; device \(nominal(dev)) Hz, agg \(nominal(io)) Hz; \(streamFormats(io, kAudioObjectPropertyScopeOutput))") }; stalls = 0 }
    lastFrames = frames
}
AudioDeviceStop(io, procID)
AudioDeviceDestroyIOProcID(io, procID)
log("stopped: \(cycles) cycles, \(frames) frames; device now \(nominal(dev)) Hz")
if agg != 0 { AudioHardwareDestroyAggregateDevice(agg) }
restore?()
if useHog { var none = pid_t(-1); var a = addr(kAudioDevicePropertyHogMode); let s = AudioObjectSetPropertyData(dev, &a, 0, nil, 4, &none); log("released hog: \(s), owner \(hogOwner(dev))") }
let nf = min(frames, maxFrames)
FileManager.default.createFile(atPath: args[3] + ".sent.f32", contents: Data(bytes: sent, count: nf * 2 * 4))
FileManager.default.createFile(atPath: args[3] + ".in.f32", contents: Data(bytes: rec, count: nf * inCh * 4))
var peaks = [Float](repeating: 0, count: inCh)
for f in 0..<nf { for c in 0..<inCh { peaks[c] = max(peaks[c], abs(rec[f * inCh + c])) } }
log("input peaks: " + peaks.map { String(format: "%.2g", $0) }.joined(separator: " "))
