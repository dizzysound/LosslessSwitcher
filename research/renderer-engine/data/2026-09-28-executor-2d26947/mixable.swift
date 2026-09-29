// mixable <UID>: put the device's first output stream back on a mixable format at its current rate
// and depth (what the engine does when it lets go). Nothing else.
import CoreAudio
import Foundation
let uid = CommandLine.arguments[1] as CFString
var dev = AudioObjectID(0); var u: CFString? = uid
var tr = AudioValueTranslation(mInputData: &u, mInputDataSize: UInt32(MemoryLayout<CFString?>.size), mOutputData: &dev, mOutputDataSize: 4)
var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDeviceForUID, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
var sz = UInt32(MemoryLayout<AudioValueTranslation>.size)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &tr)
var sa = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: 0)
var ss: UInt32 = 0; AudioObjectGetPropertyDataSize(dev, &sa, 0, nil, &ss)
var streams = [AudioStreamID](repeating: 0, count: Int(ss) / 4); AudioObjectGetPropertyData(dev, &sa, 0, nil, &ss, &streams)
let st = streams[0]
var pa = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyPhysicalFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
var cur = AudioStreamBasicDescription(); var cz = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
AudioObjectGetPropertyData(st, &pa, 0, nil, &cz, &cur)
var fa = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyAvailablePhysicalFormats, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
var fz: UInt32 = 0; AudioObjectGetPropertyDataSize(st, &fa, 0, nil, &fz)
var fmts = [AudioStreamRangedDescription](repeating: AudioStreamRangedDescription(), count: Int(fz) / MemoryLayout<AudioStreamRangedDescription>.size)
AudioObjectGetPropertyData(st, &fa, 0, nil, &fz, &fmts)
guard var f = fmts.map({ $0.mFormat }).first(where: { $0.mFormatFlags & kAudioFormatFlagIsNonMixable == 0 && $0.mBitsPerChannel == cur.mBitsPerChannel && ($0.mSampleRate == cur.mSampleRate || $0.mSampleRate == 0) }) else { print("no mixable format"); exit(1) }
if f.mSampleRate == 0 { f.mSampleRate = cur.mSampleRate }
print("set mixable \(Int(f.mSampleRate)) Hz \(f.mBitsPerChannel)-bit: \(AudioObjectSetPropertyData(st, &pa, 0, nil, UInt32(MemoryLayout<AudioStreamBasicDescription>.size), &f))")
