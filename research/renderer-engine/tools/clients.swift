import CoreAudio
import Foundation
func arr(_ o: AudioObjectID, _ sel: AudioObjectPropertySelector, _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> [AudioObjectID] {
  var a = AudioObjectPropertyAddress(mSelector: sel, mScope: scope, mElement: 0); var s = UInt32(0)
  guard AudioObjectGetPropertyDataSize(o, &a, 0, nil, &s) == 0 else { return [] }
  var v = [AudioObjectID](repeating: 0, count: Int(s)/4); AudioObjectGetPropertyData(o, &a, 0, nil, &s, &v); return v }
func u32(_ o: AudioObjectID, _ sel: AudioObjectPropertySelector) -> UInt32 { var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0); var v = UInt32(0); var s = UInt32(4); AudioObjectGetPropertyData(o, &a, 0, nil, &s, &v); return v }
func str(_ o: AudioObjectID, _ sel: AudioObjectPropertySelector) -> String { var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0); var n: Unmanaged<CFString>?; var s = UInt32(8); guard AudioObjectGetPropertyData(o, &a, 0, nil, &s, &n) == 0 else { return "?" }; return n?.takeRetainedValue() as String? ?? "?" }
let sys = AudioObjectID(kAudioObjectSystemObject)
for p in arr(sys, kAudioHardwarePropertyProcessObjectList) {
  let pid = Int32(bitPattern: u32(p, kAudioProcessPropertyPID)), out = u32(p, kAudioProcessPropertyIsRunningOutput), run = u32(p, kAudioProcessPropertyIsRunning)
  guard run != 0 || out != 0 else { continue }
  let devs = arr(p, kAudioProcessPropertyDevices, kAudioObjectPropertyScopeOutput).map { "\($0) \(str($0, kAudioObjectPropertyName))" }
  print("pid \(pid) \(str(p, kAudioProcessPropertyBundleID)) running \(run) output \(out) devices: \(devs)")
}
