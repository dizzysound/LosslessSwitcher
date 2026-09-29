// devprobe <device name>: dumps a device's streams, physical/virtual formats, channel names and
// hog-mode state. Needs no audio-capture permission, so it runs as a plain CLI.
import CoreAudio
import Foundation

func addr(_ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
          _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> AudioObjectPropertyAddress {
    .init(mSelector: s, mScope: scope, mElement: el)
}
func stringProp(_ obj: AudioObjectID, _ s: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal,
                _ el: AudioObjectPropertyElement = kAudioObjectPropertyElementMain) -> String? {
    var a = addr(s, scope, el); var v: Unmanaged<CFString>?; var z = UInt32(MemoryLayout<CFString?>.size)
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &z, &v) == noErr else { return nil }
    return v?.takeRetainedValue() as String?
}
func array<T>(_ obj: AudioObjectID, _ a: AudioObjectPropertyAddress, _ t: T.Type) -> [T] {
    var a = a; var z: UInt32 = 0
    guard AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &z) == noErr, z > 0 else { return [] }
    let n = Int(z) / MemoryLayout<T>.stride
    let p = UnsafeMutablePointer<T>.allocate(capacity: n); defer { p.deallocate() }
    guard AudioObjectGetPropertyData(obj, &a, 0, nil, &z, p) == noErr else { return [] }
    return Array(UnsafeBufferPointer(start: p, count: n))
}
func fmtString(_ f: AudioStreamBasicDescription) -> String {
    "\(f.mSampleRate) Hz \(f.mChannelsPerFrame) ch \(f.mBitsPerChannel) bit flags \(f.mFormatFlags)\(f.mFormatFlags & kAudioFormatFlagIsNonMixable != 0 ? " (non-mixable)" : "")"
}

let target = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "MT 48"
let devs = array(AudioObjectID(kAudioObjectSystemObject), addr(kAudioHardwarePropertyDevices), AudioObjectID.self)
guard let dev = devs.first(where: { stringProp($0, kAudioObjectPropertyName) == target }) else { print("no device \(target)"); exit(1) }
print("\(target): id \(dev) uid \(stringProp(dev, kAudioDevicePropertyDeviceUID) ?? "?")")
var hog = pid_t(0); var a = addr(kAudioDevicePropertyHogMode); var z = UInt32(4)
let hs = AudioObjectGetPropertyData(dev, &a, 0, nil, &z, &hog)
print("hog mode owner pid: \(hog) (status \(hs))")
for (label, scope) in [("output", kAudioObjectPropertyScopeOutput), ("input", kAudioObjectPropertyScopeInput)] {
    let streams = array(dev, addr(kAudioDevicePropertyStreams, scope), AudioStreamID.self)
    print("\(label) streams: \(streams)")
    for s in streams {
        var pf = AudioStreamBasicDescription(), vf = AudioStreamBasicDescription(); z = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        a = addr(kAudioStreamPropertyPhysicalFormat); AudioObjectGetPropertyData(s, &a, 0, nil, &z, &pf)
        a = addr(kAudioStreamPropertyVirtualFormat); AudioObjectGetPropertyData(s, &a, 0, nil, &z, &vf)
        print("  stream \(s): physical \(fmtString(pf))")
        print("             virtual  \(fmtString(vf))")
        let avail = array(s, addr(kAudioStreamPropertyAvailablePhysicalFormats), AudioStreamRangedDescription.self)
        let atRate = avail.filter { $0.mFormat.mSampleRate == pf.mSampleRate }
        for r in atRate { print("    available @ current rate: \(fmtString(r.mFormat))") }
    }
    let nch = array(dev, addr(kAudioDevicePropertyStreamConfiguration, scope), UInt8.self)
    if nch.count >= MemoryLayout<UInt32>.size {
        let n = nch.withUnsafeBytes { $0.load(as: UInt32.self) }
        var names: [String] = []
        let total = (0..<Int(n)).reduce(0) { acc, i in
            acc + Int(nch.withUnsafeBytes { $0.load(fromByteOffset: 8 + i * 16, as: UInt32.self) }) }
        for c in 1...max(total, 1) { names.append(stringProp(dev, kAudioObjectPropertyElementName, scope, UInt32(c)) ?? "-") }
        print("  \(total) \(label) channels: \(names.joined(separator: " | "))")
    }
}
var bs = UInt32(0); a = addr(kAudioDevicePropertyBufferFrameSize); z = 4; AudioObjectGetPropertyData(dev, &a, 0, nil, &z, &bs)
var lat = UInt32(0); a = addr(kAudioDevicePropertyLatency, kAudioObjectPropertyScopeOutput); AudioObjectGetPropertyData(dev, &a, 0, nil, &z, &lat)
var sl = UInt32(0); a = addr(kAudioDevicePropertySafetyOffset, kAudioObjectPropertyScopeOutput); AudioObjectGetPropertyData(dev, &a, 0, nil, &z, &sl)
print("buffer \(bs) frames, output latency \(lat), safety offset \(sl)")
// devprobe <device> mixable: clears the non-mixable flag on the output stream's current format
if CommandLine.arguments.count > 2, CommandLine.arguments[2] == "mixable" {
    let s = array(dev, addr(kAudioDevicePropertyStreams, kAudioObjectPropertyScopeOutput), AudioStreamID.self)[0]
    var f = AudioStreamBasicDescription(); var z = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
    var a = addr(kAudioStreamPropertyPhysicalFormat); AudioObjectGetPropertyData(s, &a, 0, nil, &z, &f)
    f.mFormatFlags &= ~kAudioFormatFlagIsNonMixable
    print("set mixable: \(AudioObjectSetPropertyData(s, &a, 0, nil, z, &f))")
}
