// volprobe <UID>: the output volume dB properties a device supports on elements 0-2 (read-only).
import CoreAudio
import Foundation
let uid = CommandLine.arguments[1] as CFString
var dev = AudioObjectID(0); var u: CFString? = uid
var tr = AudioValueTranslation(mInputData: &u, mInputDataSize: UInt32(MemoryLayout<CFString?>.size), mOutputData: &dev, mOutputDataSize: 4)
var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDeviceForUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
var sz = UInt32(MemoryLayout<AudioValueTranslation>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &tr)
for el: UInt32 in 0...2 {
    func f(_ s: AudioObjectPropertySelector, _ inV: Float32 = 0) -> String {
        var p = AudioObjectPropertyAddress(mSelector: s, mScope: kAudioObjectPropertyScopeOutput, mElement: el)
        guard AudioObjectHasProperty(dev, &p) else { return "none" }
        var v = inV; var z = UInt32(4)
        let st = AudioObjectGetPropertyData(dev, &p, 0, nil, &z, &v)
        return st == noErr ? String(format: "%.4f", v) : "err \(st)"
    }
    var p = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeRangeDecibels, mScope: kAudioObjectPropertyScopeOutput, mElement: el)
    var r = AudioValueRange(); var z = UInt32(MemoryLayout<AudioValueRange>.size)
    let range = AudioObjectHasProperty(dev, &p) ? (AudioObjectGetPropertyData(dev, &p, 0, nil, &z, &r) == noErr ? "\(r.mMinimum)..\(r.mMaximum)" : "err") : "none"
    print("el\(el): scalar \(f(kAudioDevicePropertyVolumeScalar)) dB \(f(kAudioDevicePropertyVolumeDecibels)) range \(range) dB->scalar(-16) \(f(kAudioDevicePropertyVolumeDecibelsToScalar, -16)) scalar->dB(0.5) \(f(kAudioDevicePropertyVolumeScalarToDecibels, 0.5))")
}
