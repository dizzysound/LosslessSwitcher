// Lists aggregate/virtual devices and the subdevices they contain.
import CoreAudio
import Foundation
func addr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress { .init(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain) }
func str(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> String { var a = addr(s); var n: Unmanaged<CFString>?; var z = UInt32(MemoryLayout<CFString?>.size); AudioObjectGetPropertyData(o, &a, 0, nil, &z, &n); return (n?.takeRetainedValue() as String?) ?? "?" }
func ids(_ o: AudioObjectID, _ s: AudioObjectPropertySelector) -> [AudioObjectID] { var a = addr(s); var z: UInt32 = 0; AudioObjectGetPropertyDataSize(o, &a, 0, nil, &z); var v = [AudioObjectID](repeating: 0, count: Int(z)/4); AudioObjectGetPropertyData(o, &a, 0, nil, &z, &v); return v }
for d in ids(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDevices) {
    var a = addr(kAudioDevicePropertyTransportType); var t: UInt32 = 0; var z = UInt32(4); AudioObjectGetPropertyData(d, &a, 0, nil, &z, &t)
    let tt = String(bytes: withUnsafeBytes(of: t.bigEndian, Array.init), encoding: .ascii) ?? "?"
    let subs = ids(d, kAudioAggregateDevicePropertyActiveSubDeviceList).map { str($0, kAudioObjectPropertyName) }
    print("\(str(d, kAudioObjectPropertyName)) [\(tt)]" + (subs.isEmpty ? "" : " subdevices: \(subs)"))
}
