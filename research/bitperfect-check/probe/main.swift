import Foundation
struct CMPlayerStats { let sampleRate: Double; let bitDepth: Int; let date: Date; let priority: Int }
print("running:", LocalTrack.isMusicRunning)
let t0 = Date()
DispatchQueue.global().async {
    let r = LocalTrack.runScript("tell application \"Music\" to return (sound volume as string) & \",\" & (EQ enabled as string)")
    print("bg script:", r ?? "nil", String(format: "%.2fs", Date().timeIntervalSince(t0)))
    CFPreferencesAppSynchronize("com.apple.Music" as CFString)
    for k in ["optimizeSongVolume", "crossfadeEnabled", "soundEnhancerEnabled", "crossfadeSeconds", "losslessEnabled"] {
        print(k, CFPreferencesCopyAppValue(k as CFString, "com.apple.Music" as CFString) as Any)
    }
    DispatchQueue.main.async { print("main queue ok"); exit(0) }
}
RunLoop.main.run(until: Date().addingTimeInterval(8)); print("timeout")
