// audioprobe: one line per output device: default flags, nominal rate, hog pid, volume, mute,
// output stream physical format. Read-only.
import CoreAudio
import Foundation

func addr(_ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    AudioObjectPropertyAddress(mSelector: s, mScope: sc, mElement: el)
}
func get<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ zero: T) -> T? {
    var a = a; var v = zero; var size = UInt32(MemoryLayout<T>.size)
    guard AudioObjectHasProperty(obj, &a) else { return nil }
    return AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr ? v : nil
}
func str(_ obj: AudioObjectID, _ s: AudioObjectPropertySelector) -> String {
    var a = addr(s); var v: Unmanaged<CFString>? = nil; var size = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &size, &v) == noErr, let v else { return "?" }
    return v.takeRetainedValue() as String
}
let sys = AudioObjectID(kAudioObjectSystemObject)
var da = addr(kAudioHardwarePropertyDevices); var size: UInt32 = 0
AudioObjectGetPropertyDataSize(sys, &da, 0, nil, &size)
var ids = [AudioObjectID](repeating: 0, count: Int(size) / 4)
AudioObjectGetPropertyData(sys, &da, 0, nil, &size, &ids)
let defOut = get(sys, addr(kAudioHardwarePropertyDefaultOutputDevice), AudioObjectID(0)) ?? 0
let defSys = get(sys, addr(kAudioHardwarePropertyDefaultSystemOutputDevice), AudioObjectID(0)) ?? 0
let out = kAudioObjectPropertyScopeOutput
for id in ids {
    var sa = addr(kAudioDevicePropertyStreams, out); var ss: UInt32 = 0
    AudioObjectGetPropertyDataSize(id, &sa, 0, nil, &ss)
    if ss == 0 { continue }
    var streams = [AudioStreamID](repeating: 0, count: Int(ss) / 4)
    AudioObjectGetPropertyData(id, &sa, 0, nil, &ss, &streams)
    let name = str(id, kAudioObjectPropertyName)
    let rate = get(id, addr(kAudioDevicePropertyNominalSampleRate), Float64(0)) ?? 0
    let hog = get(id, addr(kAudioDevicePropertyHogMode), pid_t(0)) ?? -2
    var vol = "-"
    for el: UInt32 in [0, 1, 2] {
        if let d = get(id, addr(kAudioDevicePropertyVolumeDecibels, out, el), Float32(0)) { vol += String(format: " e%u=%.1fdB", el, d) }
    }
    var mute = "-"
    for el: UInt32 in [0, 1] { if let m = get(id, addr(kAudioDevicePropertyMute, out, el), UInt32(0)) { mute = "e\(el)=\(m)"; break } }
    var fmt = ""
    if let f = get(streams[0], addr(kAudioStreamPropertyPhysicalFormat), AudioStreamBasicDescription()) {
        let flt = f.mFormatFlags & kAudioFormatFlagIsFloat != 0
        let nm = f.mFormatFlags & kAudioFormatFlagIsNonMixable != 0
        fmt = "\(flt ? "float" : "int")\(f.mBitsPerChannel)\(nm ? " nonmixable" : " mixable") \(Int(f.mSampleRate))"
    }
    let flags = (id == defOut ? "DEFAULT " : "") + (id == defSys ? "SYSTEM " : "")
    print("\(name) | \(flags)rate=\(Int(rate)) hog=\(hog) vol\(vol) mute=\(mute) | \(fmt) | \(str(id, kAudioDevicePropertyDeviceUID))")
}
