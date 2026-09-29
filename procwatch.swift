// procwatch <seconds>: logs every change of Music's Core Audio process object's
// kAudioProcessPropertyIsRunningOutput and output device list, plus the default device's rate,
// with timestamps. Needs no capture permission.
import AppKit
import CoreAudio
setvbuf(stdout, nil, _IOLBF, 0)
func addr(_ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress { .init(mSelector: s, mScope: sc, mElement: kAudioObjectPropertyElementMain) }
let t0 = Date()
func log(_ s: String) { print(String(format: "[%7.3f] ", Date().timeIntervalSince(t0)) + s) }
var pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first!.processIdentifier
var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject); var obj = AudioObjectID(0); var z = UInt32(4)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 4, &pid, &z, &obj)
a = addr(kAudioHardwarePropertyDefaultOutputDevice); var dev = AudioObjectID(0); z = 4
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &z, &dev)
func running() -> UInt32 { var r = UInt32(0); var a = addr(kAudioProcessPropertyIsRunningOutput); var z = UInt32(4); AudioObjectGetPropertyData(obj, &a, 0, nil, &z, &r); return r }
func devices() -> [AudioObjectID] {
    var a = addr(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput); var z = UInt32(0)
    AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &z); var ids = [AudioObjectID](repeating: 0, count: Int(z) / 4)
    AudioObjectGetPropertyData(obj, &a, 0, nil, &z, &ids); return ids
}
func rate() -> Float64 { var r: Float64 = 0; var a = addr(kAudioDevicePropertyNominalSampleRate); var z = UInt32(8); AudioObjectGetPropertyData(dev, &a, 0, nil, &z, &r); return r }
let q = DispatchQueue(label: "l")
log("start: running \(running()), devices \(devices()), default \(dev) @ \(rate())")
var ra = addr(kAudioProcessPropertyIsRunningOutput)
AudioObjectAddPropertyListenerBlock(obj, &ra, q) { _, _ in log("listener: IsRunningOutput -> \(running())") }
var da = addr(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput)
AudioObjectAddPropertyListenerBlock(obj, &da, q) { _, _ in log("listener: devices -> \(devices())") }
var na = addr(kAudioDevicePropertyNominalSampleRate)
AudioObjectAddPropertyListenerBlock(dev, &na, q) { _, _ in log("listener: rate -> \(rate())") }
var last = running()
let end = Date().addingTimeInterval(Double(CommandLine.arguments[1])!)
while Date() < end { Thread.sleep(forTimeInterval: 0.01); let r = running(); if r != last { log("poll: running \(last) -> \(r)"); last = r } }
