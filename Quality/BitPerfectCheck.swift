//
//  BitPerfectCheck.swift
//  LosslessSwitcher
//
//  Settings that silently change the samples Music sends to the device, shown in the menu.
//  Music's preferences are read from its defaults domain (no Apple event); volume needs one
//  Apple event, sent at most once per track change or on Refresh.
//

import AppKit
import CoreAudio
import Foundation

final class BitPerfectCheck: ObservableObject {

    struct Item: Identifiable {
        let id: String
        let ok: Bool? // nil: couldn't be read
        let text: String
    }

    @Published private(set) var items = [Item]()

    var issueCount: Int {
        items.filter { $0.ok == false }.count
    }

    private let outputDevice: () -> AudioObjectID?
    private let queue = DispatchQueue(label: "bitPerfectCheckQueue", qos: .utility)
    private var observer: NSObjectProtocol?
    private var lastRefresh = Date.distantPast // main thread only

    init(outputDevice: @escaping () -> AudioObjectID?) {
        self.outputDevice = outputDevice
        observer = DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { [weak self] _ in
            // Music posts several of these per track change; one refresh is enough.
            guard let self, Date().timeIntervalSince(lastRefresh) > 3 else { return }
            refresh()
        }
        refresh()
    }

    deinit {
        if let observer {
            DistributedNotificationCenter.default().removeObserver(observer)
        }
    }

    func refresh() {
        lastRefresh = Date()
        let device = outputDevice()
        queue.async { [weak self] in
            let items = Self.check(outputDevice: device)
            print("[BitPerfectCheck] " + items.map { "\($0.ok.map { $0 ? "ok" : "REVIEW" } ?? "?"): \($0.text)" }.joined(separator: " | "))
            DispatchQueue.main.async {
                self?.items = items
            }
        }
    }

    private static let musicDomain = "com.apple.Music" as CFString

    private static func musicPreference(_ key: String) -> Any? {
        CFPreferencesCopyAppValue(key as CFString, musicDomain)
    }

    // Keys observed on macOS 26.6.2 by toggling each setting in Music (research/bitperfect-check/log.md).
    private static func check(outputDevice: AudioObjectID?) -> [Item] {
        var items = [Item]()

        if isMusicRunning,
           let output = runScript("tell application \"Music\" to return sound volume as string"),
           let volume = Int(output) {
            items.append(Item(id: "volume", ok: volume == 100,
                              text: volume == 100 ? "Music volume 100%" : "Music volume \(volume)% (scales the samples)"))
        } else {
            items.append(Item(id: "volume", ok: nil, text: "Music volume: Music isn't running"))
        }

        // Read fresh values; Music may have changed them since the last read.
        CFPreferencesAppSynchronize(musicDomain)
        // present and 1 when on, absent when off
        let enhancer = (musicPreference("soundEnhancerEnabled") as? Bool) ?? false
        items.append(Item(id: "enhancer", ok: !enhancer, text: enhancer ? "Sound Enhancer on" : "Sound Enhancer off"))
        // 0 when off; absent when on
        let soundCheckOff = (musicPreference("optimizeSongVolume") as? Int) == 0
        items.append(Item(id: "soundCheck", ok: soundCheckOff, text: soundCheckOff ? "Sound Check off" : "Sound Check may be on (changes levels)"))
        // 30 when Off; absent when Automatic
        let atmosOff = (musicPreference("preferredDolbyAtmosPlaySetting") as? Int) == 30
        items.append(Item(id: "atmos", ok: atmosOff, text: atmosOff ? "Dolby Atmos off" : "Dolby Atmos not Off (can play the Atmos mix instead of lossless stereo)"))
        // Neither leaves a trace in Music's preferences, and AppleScript's "EQ enabled" reads false while it's on.
        items.append(Item(id: "manual", ok: nil, text: "Check in Music: Equalizer and Crossfade off"))

        if let outputDevice, let alertDevice = systemOutputDevice() {
            let separate = alertDevice != outputDevice
            items.append(Item(id: "alerts", ok: separate,
                              text: separate ? "Alert sounds play on another device" : "Alert sounds mix into this device"))
        }
        return items
    }

    private static var isMusicRunning: Bool {
        // "tell application" would launch Music if it isn't running
        !NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Music").isEmpty
    }

    private static func runScript(_ source: String) -> String? {
        var error: NSDictionary?
        let output = NSAppleScript(source: source)?.executeAndReturnError(&error).stringValue
        if let error {
            print("[BitPerfectCheck] AppleScript - \(error)")
            return nil
        }
        return output
    }

    /// The device macOS plays alert and system sounds on ("Play sound effects through").
    private static func systemOutputDevice() -> AudioObjectID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultSystemOutputDevice, mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr else { return nil }
        return device
    }
}
