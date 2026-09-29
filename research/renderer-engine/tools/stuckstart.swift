// Reproduces the coffee bench's start B failure (35 after ~7 s) without the app: cycles the DAC the
// way the engine's take-back and step-aside do (hog, non-mixable format, IOProc start/stop/destroy,
// mixable, hog released) and times each AudioDeviceStart. Outputs silence.
// Usage: stuckstart <device-name-substring> [cycles] [recovery]
//   recovery: none | restart (stop + start once more) | wait (5 s, start again) | unload
//     (AudioHardwareUnload, then a new IOProc)
// Env: GAP_MS (sleep between the hog and format changes), NOFORMAT=1 (hog only, no format changes)
import CoreAudio
import Foundation

func addr(_ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: sc, mElement: kAudioObjectPropertyElementMain)
}
func devices() -> [AudioObjectID] {
    var a = addr(kAudioHardwarePropertyDevices); var z = UInt32(0)
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &z)
    var ids = [AudioObjectID](repeating: 0, count: Int(z) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &z, &ids); return ids
}
func name(_ d: AudioObjectID) -> String {
    var a = addr(kAudioObjectPropertyName); var s: Unmanaged<CFString>?; var z = UInt32(MemoryLayout<CFString?>.size)
    AudioObjectGetPropertyData(d, &a, 0, nil, &z, &s); return (s?.takeRetainedValue() as String?) ?? "?"
}
func outStream(_ d: AudioObjectID) -> AudioStreamID? {
    var a = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput); var z = UInt32(0)
    AudioObjectGetPropertyDataSize(d, &a, 0, nil, &z); guard z > 0 else { return nil }
    var ids = [AudioStreamID](repeating: 0, count: Int(z) / 4)
    AudioObjectGetPropertyData(d, &a, 0, nil, &z, &ids); return ids.first
}
func physical(_ s: AudioStreamID) -> AudioStreamBasicDescription {
    var f = AudioStreamBasicDescription(); var z = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var a = addr(kAudioStreamPropertyPhysicalFormat); AudioObjectGetPropertyData(s, &a, 0, nil, &z, &f); return f
}
func setPhysical(_ s: AudioStreamID, _ f: AudioStreamBasicDescription) -> OSStatus {
    var f = f; var a = addr(kAudioStreamPropertyPhysicalFormat)
    return AudioObjectSetPropertyData(s, &a, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &f)
}
func setHog(_ d: AudioObjectID, _ pid: pid_t) -> OSStatus {
    var p = pid; var a = addr(kAudioDevicePropertyHogMode)
    return AudioObjectSetPropertyData(d, &a, 0, nil, 4, &p)
}
func ms(_ t: Date) -> String { String(format: "%.0f ms", Date().timeIntervalSince(t) * 1000) }

let args = CommandLine.arguments
guard args.count > 1, let dac = devices().first(where: { name($0).contains(args[1]) }), let s = outStream(dac) else {
    print("usage: stuckstart <device-name-substring> [cycles] [none|restart|wait]"); exit(1)
}
let cycles = args.count > 2 ? Int(args[2]) ?? 20 : 20
let recovery = args.count > 3 ? args[3] : "restart"
let env = ProcessInfo.processInfo.environment
let gap = Double(env["GAP_MS"] ?? "0")! / 1000
let noFormat = env["NOFORMAT"] == "1"
func gapSleep() { if gap > 0 { Thread.sleep(forTimeInterval: gap) } }
let mixable = physical(s)
var nonMix = mixable; nonMix.mFormatFlags |= kAudioFormatFlagIsNonMixable
print("\(name(dac)) \(dac): phys \(mixable.mSampleRate) Hz \(mixable.mBitsPerChannel) bit flags \(mixable.mFormatFlags); \(cycles) cycles, recovery \(recovery)")

var fails = 0
for i in 1...cycles {
    print("[\(i)] hog \(setHog(dac, getpid()))", terminator: " "); gapSleep()
    print("non-mixable \(noFormat ? 0 : setPhysical(s, nonMix))", terminator: "; "); if !noFormat { gapSleep() }
    func makeProc() -> AudioDeviceIOProcID {
        var proc: AudioDeviceIOProcID?
        AudioDeviceCreateIOProcIDWithBlock(&proc, dac, nil) { _, _, _, out, _ in
            for b in UnsafeMutableAudioBufferListPointer(out) { if let p = b.mData { memset(p, 0, Int(b.mDataByteSize)) } }
        }
        guard let proc else { print("no IOProc"); exit(1) }
        return proc
    }
    var proc = makeProc()
    var t = Date()
    var st = AudioDeviceStart(dac, proc)
    print("start \(st) after \(ms(t))", terminator: "")
    if st != noErr {
        fails += 1
        switch recovery {
        case "restart":
            AudioDeviceStop(dac, proc); t = Date(); st = AudioDeviceStart(dac, proc)
            print("; stop+start \(st) after \(ms(t))", terminator: "")
        case "unload":
            AudioDeviceStop(dac, proc); AudioDeviceDestroyIOProcID(dac, proc)
            print("; unload \(AudioHardwareUnload())", terminator: "")
            print(", hog owner mine \({ () -> Bool in var h = pid_t(0); var a = addr(kAudioDevicePropertyHogMode); var z = UInt32(4); AudioObjectGetPropertyData(dac, &a, 0, nil, &z, &h); return h == getpid() }())", terminator: "")
            proc = makeProc(); t = Date(); st = AudioDeviceStart(dac, proc)
            print("; new IOProc start \(st) after \(ms(t))", terminator: "")
        case "wait":
            AudioDeviceStop(dac, proc); Thread.sleep(forTimeInterval: 5); t = Date(); st = AudioDeviceStart(dac, proc)
            print("; after 5 s: start \(st) after \(ms(t))", terminator: "")
        default: break
        }
    }
    print("")
    Thread.sleep(forTimeInterval: 0.4)
    AudioDeviceStop(dac, proc)
    AudioDeviceDestroyIOProcID(dac, proc)
    print("    mixable \(noFormat ? 0 : setPhysical(s, mixable))", terminator: " "); if !noFormat { gapSleep() }
    print("hog released \(setHog(dac, -1))")
    Thread.sleep(forTimeInterval: 0.6)
    if fails >= (recovery == "unload" ? 3 : 2) { break }
}
_ = setPhysical(s, mixable); _ = setHog(dac, -1)
print("done: \(fails) failed start(s)")
