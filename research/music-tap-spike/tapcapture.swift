// tapcapture <device|mixdown> <seconds> <out.f32> [log.txt]
// Taps the Music app's audio with a Core Audio process tap (macOS 14.4+), records it as raw
// float32 interleaved for <seconds>, and prints the tap format. Music keeps playing normally.
import AppKit
import CoreAudio
import Foundation

func fail(_ msg: String, _ status: OSStatus = 0) -> Never {
    FileHandle.standardError.write("\(msg) (\(status))\n".data(using: .utf8)!); exit(1)
}
func addr(_ s: AudioObjectPropertySelector) -> AudioObjectPropertyAddress {
    .init(mSelector: s, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
}
func stringProp(_ obj: AudioObjectID, _ s: AudioObjectPropertySelector) -> String {
    var a = addr(s); var v: Unmanaged<CFString>?; var z = UInt32(MemoryLayout<CFString?>.size)
    AudioObjectGetPropertyData(obj, &a, 0, nil, &z, &v); return (v?.takeRetainedValue() as String?) ?? ""
}

let args = CommandLine.arguments
// Launched as an app via `open`, stdout goes nowhere; an optional log path captures it.
if args.count == 5 { freopen(args[4], "w", stdout); freopen(args[4], "a", stderr); setvbuf(stdout, nil, _IOLBF, 0) }
guard args.count >= 4, let seconds = Double(args[2]) else { fail("usage: tapcapture <device|mixdown> <seconds> <out.f32> [log.txt]") }
let mode = args[1], outPath = args[3]

guard let music = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first else { fail("Music isn't running") }
var pid = music.processIdentifier
var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject)
var process = AudioObjectID(0); var size = UInt32(MemoryLayout<AudioObjectID>.size)
var st = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &process)
guard st == noErr, process != 0 else { fail("no Core Audio process object for Music pid \(pid)", st) }

a = addr(kAudioHardwarePropertyDefaultOutputDevice)
var output = AudioObjectID(0); size = 4
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &size, &output)
let outputUID = stringProp(output, kAudioDevicePropertyDeviceUID)
var nominal: Float64 = 0; a = addr(kAudioDevicePropertyNominalSampleRate); size = 8
AudioObjectGetPropertyData(output, &a, 0, nil, &size, &nominal)
print("output device \(stringProp(output, kAudioObjectPropertyName)) @ \(nominal) Hz, Music process object \(process)")

let desc = mode == "device"
    ? CATapDescription(processes: [process], deviceUID: outputUID, stream: 0)
    : CATapDescription(stereoMixdownOfProcesses: [process])
desc.uuid = UUID(); desc.isPrivate = true; desc.muteBehavior = .unmuted; desc.name = "tapcapture"
var tap = AudioObjectID(0)
st = AudioHardwareCreateProcessTap(desc, &tap)
guard st == noErr else { fail("AudioHardwareCreateProcessTap failed", st) }

var fmt = AudioStreamBasicDescription(); a = addr(kAudioTapPropertyFormat); size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
st = AudioObjectGetPropertyData(tap, &a, 0, nil, &size, &fmt)
print("tap format: \(fmt.mSampleRate) Hz, \(fmt.mChannelsPerFrame) ch, \(fmt.mBitsPerChannel) bit, flags \(fmt.mFormatFlags), bytes/frame \(fmt.mBytesPerFrame)")

let aggUID = UUID().uuidString
let aggDesc: [String: Any] = [
    kAudioAggregateDeviceUIDKey: aggUID,
    kAudioAggregateDeviceNameKey: "tapcapture",
    kAudioAggregateDeviceIsPrivateKey: 1,
    kAudioAggregateDeviceMainSubDeviceKey: outputUID,
    kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
    kAudioAggregateDeviceTapListKey: [[kAudioSubTapUIDKey: desc.uuid.uuidString, kAudioSubTapDriftCompensationKey: 0]],
    kAudioAggregateDeviceTapAutoStartKey: 1,
]
var agg = AudioObjectID(0)
st = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
guard st == noErr else { AudioHardwareDestroyProcessTap(tap); fail("AudioHardwareCreateAggregateDevice failed", st) }
var aggRate: Float64 = 0; a = addr(kAudioDevicePropertyNominalSampleRate); size = 8
AudioObjectGetPropertyData(agg, &a, 0, nil, &size, &aggRate)
print("aggregate @ \(aggRate) Hz")

let channels = max(Int(fmt.mChannelsPerFrame), 2)
let capacity = Int((seconds + 2) * max(fmt.mSampleRate, 48000)) * channels
let samples = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
var count = 0 // written only on the IO thread
var callbacks = 0, inputBufferShape = ""
var procID: AudioDeviceIOProcID?
st = AudioDeviceCreateIOProcIDWithBlock(&procID, agg, nil) { _, inInput, _, _, _ in
    let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: inInput))
    callbacks += 1
    if inputBufferShape.isEmpty { inputBufferShape = abl.map { "\($0.mNumberChannels)ch/\($0.mDataByteSize)B" }.joined(separator: ",") }
    // the tap is the last input stream of the aggregate (after the output device's own inputs, if any)
    guard let buf = abl.last, let data = buf.mData else { return }
    let n = Int(buf.mDataByteSize) / MemoryLayout<Float>.size
    let take = min(n, capacity - count)
    if take > 0 { (samples + count).update(from: data.assumingMemoryBound(to: Float.self), count: take); count += take }
}
guard st == noErr, let procID else { fail("IOProc failed", st) }
st = AudioDeviceStart(agg, procID)
guard st == noErr else { fail("AudioDeviceStart failed", st) }
print("recording \(seconds) s...")
Thread.sleep(forTimeInterval: seconds)
AudioDeviceStop(agg, procID)
AudioDeviceDestroyIOProcID(agg, procID)
AudioHardwareDestroyAggregateDevice(agg)
AudioHardwareDestroyProcessTap(tap)

FileManager.default.createFile(atPath: outPath, contents: Data(bytes: samples, count: count * 4))
var peak: Float = 0; for i in 0..<count { peak = max(peak, abs(samples[i])) }
print("callbacks \(callbacks), input buffers [\(inputBufferShape)], wrote \(count) samples = \(count / channels) frames x \(channels) ch (\(String(format: "%.1f", Double(count / channels) / max(fmt.mSampleRate, 1))) s), peak \(peak)")
