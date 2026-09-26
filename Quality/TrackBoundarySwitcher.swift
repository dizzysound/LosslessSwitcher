//
//  TrackBoundarySwitcher.swift
//  LosslessSwitcher
//
//  Opt-in "Pause While Switching": when Music starts a local track that needs a different
//  device format, pause Music, switch the device, wait until the device reports the new
//  format steadily, then restart the track from 0:00. Music stays paused if the device
//  never settles, rather than playing through a rate change.
//
//  Music's com.apple.Music.playerInfo notification arrives the moment a track starts, but it
//  carries no file location, so a fraction of a second of the new track still plays at the
//  old rate before the pause.
//

import AudioToolbox
import CoreAudio
import Foundation
import SimplyCoreAudio

class TrackBoundarySwitcher {

    static let settleTimeout: TimeInterval = 5
    static let settlePollInterval: TimeInterval = 0.025
    static let settleStableReads = 4 // consecutive matching reads before resuming (~100 ms)

    /// Extra wait after CoreAudio reports the new format: the DAC still has to lock its clock,
    /// and no HAL property reports that. Starting values; tune per device.
    static func postSettleHold(for sampleRate: Float64) -> TimeInterval {
        sampleRate > 96000 ? 1.0 : 0.5
    }

    private unowned let outputDevices: OutputDevices
    // Own queue: the regular detection path's AppleScript calls can block for seconds while Music is busy.
    private let queue = DispatchQueue(label: "trackBoundaryQueue", qos: .userInitiated)
    private var observer: NSObjectProtocol?
    private var lastPersistentID: Int64? // main thread only
    // Compiled once and only used on `queue`: compiling on every track change delayed the pause.
    private let scripts = MusicPlayer.CompiledScripts()

    init(outputDevices: OutputDevices) {
        self.outputDevices = outputDevices
        observer = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] note in
            self?.playerInfoDidChange(note.userInfo ?? [:])
        }
        // A track already playing at launch sends no notification; switch it without pausing.
        queue.async { [weak self] in
            guard Defaults.shared.userPreferPauseWhileSwitching else { return }
            self?.switchCurrentTrack(pauseMusic: false, persistentID: nil, received: Date())
        }
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    private func playerInfoDidChange(_ info: [AnyHashable : Any]) {
        guard info["Player State"] as? String == "Playing",
              let persistentID = (info["PersistentID"] as? NSNumber)?.int64Value else { return }
        // the notification repeats for the same track, and fires again when we resume
        guard persistentID != lastPersistentID else { return }
        lastPersistentID = persistentID
        guard Defaults.shared.userPreferPauseWhileSwitching else { return }

        let received = Date()
        queue.async { [weak self] in
            self?.switchCurrentTrack(pauseMusic: true, persistentID: MusicPlayer.hexPersistentID(persistentID), received: received)
        }
    }

    private func switchCurrentTrack(pauseMusic: Bool, persistentID: String?, received: Date) {
        guard let stats = currentStats(),
              let device = outputDevices.selectedOutputDevice ?? outputDevices.defaultOutputDevice,
              let format = outputDevices.suitableFormat(for: stats, device: device) else { return }

        let checkBitDepth = outputDevices.enableBitDepthDetection
        if DeviceFormat.matches(device.id, format: format, checkBitDepth: checkBitDepth) {
            return
        }

        guard pauseMusic, let persistentID else {
            outputDevices.apply(format, device: device, force: true)
            return
        }

        guard scripts.pause() else {
            print("[TrackBoundary] could not pause Music; switching during playback")
            outputDevices.apply(format, device: device, force: true)
            return
        }
        print("[TrackBoundary] paused \(persistentID) \(Self.ms(since: received)) after track start, switching to \(format.mSampleRate) Hz / \(format.mBitsPerChannel) bit")
        outputDevices.apply(format, device: device, force: true)

        let switched = Date()
        guard DeviceFormat.waitUntilSettled(device.id, format: format, checkBitDepth: checkBitDepth) else {
            print("[TrackBoundary] device did not settle within \(Self.settleTimeout)s; leaving Music paused")
            return
        }
        let hold = Self.postSettleHold(for: format.mSampleRate)
        print("[TrackBoundary] settled \(Self.ms(since: switched)) after switching; holding \(Int(hold * 1000)) ms")
        Thread.sleep(forTimeInterval: hold)

        // don't resume if the user moved on or pressed play themselves while we waited
        guard MusicPlayer.isPaused(on: persistentID) else { return }
        MusicPlayer.restart()
        print("[TrackBoundary] resumed \(Self.ms(since: received)) after track start")
    }

    /// Music's own sample rate for the current local track is one round trip and no file I/O.
    /// The file header is only read when bit depth matters.
    private func currentStats() -> CMPlayerStats? {
        if !outputDevices.enableBitDepthDetection, let sampleRate = scripts.localSampleRate(attempts: 5) {
            return CMPlayerStats(sampleRate: sampleRate, bitDepth: 24, date: Date(), priority: 100)
        }
        return LocalTrack.currentStats(attempts: 5)
    }

    private static func ms(since date: Date) -> String {
        String(format: "%.0f ms", Date().timeIntervalSince(date) * 1000)
    }
}

enum DeviceFormat {

    static func nominalSampleRate(_ device: AudioObjectID) -> Float64? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyNominalSampleRate, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var rate: Float64 = 0
        var size = UInt32(MemoryLayout<Float64>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &rate) == noErr else { return nil }
        return rate
    }

    static func physicalFormat(_ device: AudioObjectID) -> AudioStreamBasicDescription? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams, mScope: kAudioObjectPropertyScopeOutput, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr, size > 0 else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(size) / MemoryLayout<AudioStreamID>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &streams) == noErr, let stream = streams.first else { return nil }

        address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyPhysicalFormat, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &size, &format) == noErr else { return nil }
        return format
    }

    /// Both the device's nominal rate and its output stream's physical format report the target.
    static func matches(_ device: AudioObjectID, format: AudioStreamBasicDescription, checkBitDepth: Bool) -> Bool {
        guard nominalSampleRate(device) == format.mSampleRate,
              let physical = physicalFormat(device),
              physical.mSampleRate == format.mSampleRate else { return false }
        return !checkBitDepth || physical.mBitsPerChannel == format.mBitsPerChannel
    }

    static func waitUntilSettled(_ device: AudioObjectID, format: AudioStreamBasicDescription, checkBitDepth: Bool,
                                 timeout: TimeInterval = TrackBoundarySwitcher.settleTimeout) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        var stableReads = 0
        while Date() < deadline {
            stableReads = matches(device, format: format, checkBitDepth: checkBitDepth) ? stableReads + 1 : 0
            if stableReads >= TrackBoundarySwitcher.settleStableReads {
                return true
            }
            Thread.sleep(forTimeInterval: TrackBoundarySwitcher.settlePollInterval)
        }
        return false
    }
}

enum MusicPlayer {

    /// AppleScript's persistent ID is the notification's signed 64-bit value as 16 hex digits.
    static func hexPersistentID(_ id: Int64) -> String {
        String(format: "%016llX", UInt64(bitPattern: id))
    }

    /// Not thread-safe: use each instance from one queue.
    final class CompiledScripts {
        private let pauseScript = compile("tell application \"Music\" to pause")
        private let localSampleRateScript = compile("""
        tell application "Music"
            if player state is stopped then return ""
            set t to current track
            if class of t is not file track then return ""
            try
                if cloud status of t is subscription then return ""
            end try
            if location of t is missing value then return ""
            return (sample rate of t) as string
        end tell
        """)

        private static func compile(_ source: String) -> NSAppleScript? {
            let script = NSAppleScript(source: source)
            var error: NSDictionary?
            script?.compileAndReturnError(&error)
            if let error { print("[APPLESCRIPT] compile - \(error)") }
            return script
        }

        private func run(_ script: NSAppleScript?) -> String? {
            var error: NSDictionary?
            let output = script?.executeAndReturnError(&error).stringValue
            if let error {
                print("[APPLESCRIPT] - \(error)")
                return nil
            }
            return output ?? ""
        }

        func pause() -> Bool {
            run(pauseScript) != nil
        }

        /// nil when the current track isn't a local file, or Music keeps erroring.
        func localSampleRate(attempts: Int) -> Double? {
            guard LocalTrack.isMusicRunning else { return nil }
            var output = run(localSampleRateScript)
            for _ in 1..<max(attempts, 1) where output == nil {
                Thread.sleep(forTimeInterval: 0.1)
                output = run(localSampleRateScript)
            }
            guard let output, let sampleRate = Double(output), sampleRate > 0 else { return nil }
            return sampleRate
        }
    }

    static func isPaused(on persistentID: String) -> Bool {
        let script = """
        tell application "Music"
            return (player state as string) & " " & persistent ID of current track
        end tell
        """
        let state = LocalTrack.runScript(script)
        if state != "paused \(persistentID)" {
            print("[TrackBoundary] not resuming: Music reports \(state ?? "an error")")
            return false
        }
        return true
    }

    static func restart() {
        _ = LocalTrack.runScript("""
        tell application "Music"
            set player position to 0
            play
        end tell
        """)
    }
}
