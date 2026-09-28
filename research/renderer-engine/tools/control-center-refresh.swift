// Control Center's Sound menu once left the DAC out after the engine released it (Babyface bench,
// 2026-09-28; `killall ControlCenter` brought it back; not reproduced in two tries after that). Next
// time, run this BEFORE killall: it creates a public, empty aggregate device for 0.3 s, which changes
// the device list for every process without touching a real device. If the DAC comes back in the
// menu, the engine can do this on release.
//   swiftc -O -o /tmp/cc-refresh control-center-refresh.swift && /tmp/cc-refresh
import CoreAudio
import Foundation
let desc: [String: Any] = [kAudioAggregateDeviceUIDKey: "LosslessSwitcher.refresh." + UUID().uuidString,
                           kAudioAggregateDeviceNameKey: "LosslessSwitcher refresh",
                           kAudioAggregateDeviceIsPrivateKey: 0,
                           kAudioAggregateDeviceSubDeviceListKey: [] as [Any]]
var agg = AudioObjectID(0)
let st = AudioHardwareCreateAggregateDevice(desc as CFDictionary, &agg)
print("create: \(st), id \(agg)")
Thread.sleep(forTimeInterval: 0.3)
if st == noErr { print("destroy: \(AudioHardwareDestroyAggregateDevice(agg))") }
