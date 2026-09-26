// lockprobe <device name> <from Hz> <to Hz>
// Switches the device rate and logs, every 5 ms for 4 s, every status value that changes:
// nominal rate, stream physical rate, latency, safety offset, running flags, clock-is-stable,
// and (with our own silent IOProc running) the HAL's measured clock rate scalar.
import CoreAudio
import Foundation

func addr(_ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: sc, mElement: kAudioObjectPropertyElementMain)
}
func get<T>(_ obj: AudioObjectID, _ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, _ v: T) -> T? {
    var a = addr(s, sc); var val = v; var size = UInt32(MemoryLayout<T>.size)
    guard AudioObjectHasProperty(obj, &a) else { return nil }
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &val) == noErr ? val : nil
}
func devices() -> [AudioDeviceID] {
    var a = addr(kAudioHardwarePropertyDevices); var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids); return ids
}
func name(_ id: AudioDeviceID) -> String {
    var a = addr(kAudioObjectPropertyName); var n: Unmanaged<CFString>?; var s = UInt32(MemoryLayout<CFString?>.size)
    AudioObjectGetPropertyData(id, &a, 0, nil, &s, &n); return (n?.takeRetainedValue() as String?) ?? "?"
}
setvbuf(stdout, nil, _IOLBF, 0)
let args = CommandLine.arguments
guard let dev = devices().first(where: { name($0) == args[1] }) else { print("no device"); exit(1) }
var from = Float64(args[2])!, to = Float64(args[3])!
var sa = addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput); var ssize: UInt32 = 0
AudioObjectGetPropertyDataSize(dev, &sa, 0, nil, &ssize)
var streams = [AudioStreamID](repeating: 0, count: Int(ssize) / 4); AudioObjectGetPropertyData(dev, &sa, 0, nil, &ssize, &streams)

func setRate(_ r: Float64) { var a = addr(kAudioDevicePropertyNominalSampleRate); var v = r; AudioObjectSetPropertyData(dev, &a, 0, nil, 8, &v) }

// silent IOProc so the device runs and the HAL measures its clock
var procID: AudioDeviceIOProcID?
AudioDeviceCreateIOProcIDWithBlock(&procID, dev, nil) { _, _, _, outData, _ in
    let abl = UnsafeMutableAudioBufferListPointer(outData)
    for b in abl { if let d = b.mData { memset(d, 0, Int(b.mDataByteSize)) } }
}

func snapshot() -> [String: String] {
    var s = [String: String]()
    s["nominal"] = get(dev, kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0)).map { "\(Int($0))" } ?? "-"
    if let st = streams.first { s["physical"] = get(st, kAudioStreamPropertyPhysicalFormat, kAudioObjectPropertyScopeGlobal, AudioStreamBasicDescription()).map { "\(Int($0.mSampleRate))" } ?? "-" }
    s["actual"] = get(dev, kAudioDevicePropertyActualSampleRate, kAudioObjectPropertyScopeGlobal, Float64(0)).map { String(format: "%.1f", $0) } ?? "-"
    s["latency"] = get(dev, kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput, UInt32(0)).map { "\($0)" } ?? "-"
    s["safety"] = get(dev, kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput, UInt32(0)).map { "\($0)" } ?? "-"
    s["running"] = get(dev, kAudioDevicePropertyDeviceIsRunning, kAudioObjectPropertyScopeGlobal, UInt32(0)).map { "\($0)" } ?? "-"
    s["alive"] = get(dev, kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal, UInt32(0)).map { "\($0)" } ?? "-"
    s["clockStable"] = get(dev, AudioObjectPropertySelector(0x63737462) /* cstb, ClockIsStable */, kAudioObjectPropertyScopeGlobal, UInt32(0)).map { "\($0)" } ?? "-"
    s["clockSource"] = get(dev, kAudioDevicePropertyClockSource, kAudioObjectPropertyScopeOutput, UInt32(0)).map { "\($0)" } ?? "-"
    var ts = AudioTimeStamp()
    s["rateScalar"] = AudioDeviceGetCurrentTime(dev, &ts) == noErr ? String(format: "%.3f", ts.mRateScalar) : "not running"
    return s
}

setRate(from); Thread.sleep(forTimeInterval: 2)
AudioDeviceStart(dev, procID); Thread.sleep(forTimeInterval: 1)
let t0 = Date(); var last = snapshot()
print("t=0 before:", last.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " "))
setRate(to)
while Date().timeIntervalSince(t0) < 4 {
    let now = snapshot()
    let changed = now.filter { last[$0.key] != $0.value }
    if !changed.isEmpty { print(String(format: "t=%4.0f ms", Date().timeIntervalSince(t0) * 1000), changed.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")) }
    last = now; Thread.sleep(forTimeInterval: 0.005)
}
AudioDeviceStop(dev, procID); AudioDeviceDestroyIOProcID(dev, procID!)
