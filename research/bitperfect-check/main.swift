// Harness: run Quality/BitPerfectCheck.swift against the current output device and print the items.
import CoreAudio
import Foundation
struct CMPlayerStats { let sampleRate: Double; let bitDepth: Int; let date: Date; let priority: Int }
var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
var device = AudioObjectID(0); var size = UInt32(4)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device)
let check = BitPerfectCheck(outputDevice: { device })
RunLoop.main.run(until: Date().addingTimeInterval(6))
for item in check.items { print(item.ok == false ? "!!" : item.ok == true ? "ok" : "??", item.text) }
print("issues:", check.issueCount)
