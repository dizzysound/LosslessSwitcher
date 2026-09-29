import CoreAudio
func get<T>(_ id: AudioObjectID, _ sel: AudioObjectPropertySelector, _ v: T) -> T { var v = v; var a = AudioObjectPropertyAddress(mSelector: sel, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0); var s = UInt32(MemoryLayout<T>.size); AudioObjectGetPropertyData(id, &a, 0, nil, &s, &v); return v }
var a = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0)
var sz = UInt32(0); AudioObjectGetPropertyDataSize(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz)
var ids = [AudioObjectID](repeating: 0, count: Int(sz)/4); AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &a, 0, nil, &sz, &ids)
let def = get(AudioObjectID(kAudioObjectSystemObject), kAudioHardwarePropertyDefaultOutputDevice, AudioObjectID(0))
for id in ids {
  var n: Unmanaged<CFString>?; var s = UInt32(8); var p = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal, mElement: 0); AudioObjectGetPropertyData(id, &p, 0, nil, &s, &n)
  let rs = get(id, kAudioDevicePropertyDeviceIsRunningSomewhere, UInt32(0)), alive = get(id, kAudioDevicePropertyDeviceIsAlive, UInt32(0)), hog = get(id, kAudioDevicePropertyHogMode, pid_t(0))
  print(id, n?.takeRetainedValue() ?? "" as CFString, "runningSomewhere", rs, "alive", alive, "hog", hog, id == def ? "DEFAULT" : "")
}
