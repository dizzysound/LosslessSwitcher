// audioctl: minimal CoreAudio helper for the resampling test.
// usage: audioctl list | default | set-default <name> | rate <name> | set-rate <name> <hz>
import CoreAudio
import Foundation

func prop(_ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: kAudioObjectPropertyElementMain)
}
func devices() -> [AudioDeviceID] {
    var a = prop(kAudioHardwarePropertyDevices); var size: UInt32 = 0
    AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size)
    var ids = [AudioDeviceID](repeating: 0, count: Int(size) / 4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &ids)
    return ids
}
func name(_ id: AudioDeviceID) -> String {
    var a = prop(kAudioObjectPropertyName); var n: Unmanaged<CFString>?; var s = UInt32(MemoryLayout<CFString?>.size)
    AudioObjectGetPropertyData(id, &a, 0, nil, &s, &n); return (n?.takeRetainedValue() as String?) ?? "?"
}
func rate(_ id: AudioDeviceID) -> Double {
    var a = prop(kAudioDevicePropertyNominalSampleRate); var r: Float64 = 0; var s = UInt32(8)
    AudioObjectGetPropertyData(id, &a, 0, nil, &s, &r); return r
}
func find(_ n: String) -> AudioDeviceID {
    guard let d = devices().first(where: { name($0) == n }) else { fputs("no device \(n)\n", stderr); exit(1) }; return d
}
func defaultOut() -> AudioDeviceID {
    var a = prop(kAudioHardwarePropertyDefaultOutputDevice); var d = AudioDeviceID(0); var s = UInt32(4)
    AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &s, &d); return d
}
let args = CommandLine.arguments
switch args.count > 1 ? args[1] : "" {
case "list": for d in devices() { print("\(name(d))\t\(rate(d))") }
case "default": print(name(defaultOut()))
case "set-default":
    var d = find(args[2]); var a = prop(kAudioHardwarePropertyDefaultOutputDevice)
    let st = AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, 4, &d); print("status \(st)")
case "rate": print(rate(find(args[2])))
case "set-rate":
    let d = find(args[2]); var r = Float64(args[3])!; var a = prop(kAudioDevicePropertyNominalSampleRate)
    let st = AudioObjectSetPropertyData(d, &a, 0, nil, 8, &r); Thread.sleep(forTimeInterval: 0.5); print("status \(st) now \(rate(d))")
default: print("usage: audioctl list|default|set-default <name>|rate <name>|set-rate <name> <hz>")
}
