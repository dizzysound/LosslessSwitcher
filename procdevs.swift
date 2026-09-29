// procdevs: which output devices is Music's Core Audio process object using right now?
import AppKit
import CoreAudio
func addr(_ s: AudioObjectPropertySelector, _ sc: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress { .init(mSelector: s, mScope: sc, mElement: kAudioObjectPropertyElementMain) }
var pid = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").first!.processIdentifier
var a = addr(kAudioHardwarePropertyTranslatePIDToProcessObject); var obj = AudioObjectID(0); var z = UInt32(4)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 4, &pid, &z, &obj)
a = addr(kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput); z = 0
AudioObjectGetPropertyDataSize(obj, &a, 0, nil, &z)
var ids = [AudioObjectID](repeating: 0, count: Int(z) / 4); AudioObjectGetPropertyData(obj, &a, 0, nil, &z, &ids)
var run = UInt32(0); a = addr(kAudioProcessPropertyIsRunningOutput); z = 4; AudioObjectGetPropertyData(obj, &a, 0, nil, &z, &run)
for d in ids { var n: Unmanaged<CFString>?; a = addr(kAudioObjectPropertyName); z = 8; AudioObjectGetPropertyData(d, &a, 0, nil, &z, &n); print("Music output device: \(n!.takeRetainedValue())") }
print("Music running output: \(run)")
