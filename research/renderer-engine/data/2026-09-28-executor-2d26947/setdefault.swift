// setdefault <device UID>: make that device the default output. Nothing else.
import CoreAudio
import Foundation
let uid = CommandLine.arguments[1] as CFString
var dev = AudioObjectID(0); var u: CFString? = uid
var tr = AudioValueTranslation(mInputData: &u, mInputDataSize: UInt32(MemoryLayout<CFString?>.size), mOutputData: &dev, mOutputDataSize: UInt32(MemoryLayout<AudioObjectID>.size))
var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDeviceForUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var sz = UInt32(MemoryLayout<AudioValueTranslation>.size)
guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &tr) == noErr, dev != 0 else { print("no device"); exit(1) }
var d = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
print("set default: \(AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject), &d, 0, nil, UInt32(MemoryLayout<AudioObjectID>.size), &dev))")
