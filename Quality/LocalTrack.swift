//
//  LocalTrack.swift
//  LosslessSwitcher
//
//  Local (non-streaming) track detection. Asks Music for the current track's file,
//  then reads the sample rate and bit depth from the file itself.
//
//  Discussion #74 removed this because Music used to resample local files to the device
//  rate captured at launch. That no longer reproduces on macOS 26.6.2; see
//  research/local-file-resampling/log.md.
//

import AVFoundation
import AppKit
import AudioToolbox

enum LocalTrack {

    // Returns "" unless the current track is a local file with a location on disk.
    // Apple Music tracks (streamed or downloaded) are left to the log-based detection.
    private static let locationScript = """
    tell application "Music"
        if player state is stopped then return ""
        set t to current track
        if class of t is not file track then return ""
        try
            if cloud status of t is subscription then return ""
        end try
        set loc to location of t
    end tell
    if loc is missing value then return ""
    return POSIX path of loc
    """

    private static let sampleRateScript = "tell application \"Music\" to get sample rate of current track"

    static var isMusicRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    static func currentStats() -> CMPlayerStats? {
        // "tell application" would launch Music if it isn't running
        guard isMusicRunning else { return nil }
        guard let path = runScript(locationScript), !path.isEmpty else { return nil }

        if let stats = readFormat(url: URL(fileURLWithPath: path)) {
            print("[LocalTrack] \(path) -> \(stats)")
            return stats
        }

        // file unreadable (e.g. privacy-protected folder); fall back to Music's metadata
        if let output = runScript(sampleRateScript), let sampleRate = Double(output) {
            print("[LocalTrack] \(path) -> AppleScript sample rate \(sampleRate)")
            return CMPlayerStats(sampleRate: sampleRate, bitDepth: 24, date: Date(), priority: 100)
        }
        return nil
    }

    static func readFormat(url: URL) -> CMPlayerStats? {
        guard let file = try? AVAudioFile(forReading: url) else { return nil }
        let asbd = file.fileFormat.streamDescription.pointee
        guard asbd.mSampleRate > 0 else { return nil }
        return CMPlayerStats(sampleRate: asbd.mSampleRate, bitDepth: bitDepth(of: asbd), date: Date(), priority: 100)
    }

    static func bitDepth(of asbd: AudioStreamBasicDescription) -> Int {
        if asbd.mBitsPerChannel > 0 { // PCM: WAV, AIFF, CAF
            return Int(asbd.mBitsPerChannel)
        }
        // lossless codecs store the source bit depth in the format flags
        if asbd.mFormatID == kAudioFormatAppleLossless || asbd.mFormatID == kAudioFormatFLAC {
            switch asbd.mFormatFlags {
            case kAppleLosslessFormatFlag_16BitSourceData: return 16
            case kAppleLosslessFormatFlag_20BitSourceData: return 20
            case kAppleLosslessFormatFlag_24BitSourceData: return 24
            case kAppleLosslessFormatFlag_32BitSourceData: return 32
            default: break
            }
        }
        return 16 // lossy
    }

    private static func runScript(_ source: String) -> String? {
        var error: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
        if let error = error {
            print("[APPLESCRIPT] - \(error)")
            return nil
        }
        if output == "missing value" { return nil }
        return output
    }
}
