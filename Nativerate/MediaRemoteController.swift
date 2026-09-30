//
//  MediaRemoteController.swift
//  Nativerate
//
//  Created by Vincent Neo on 1/5/22.
//

import Cocoa
//import Combine
//import PrivateMediaRemote
import MediaRemoteAdapter

fileprivate let kMusicAppBundle = "com.apple.Music"

class MediaRemoteController {
    
    private let controller: MediaController
    private var stopped = false
    private var startedAt = Date()
    private var quickRestarts = 0

    init(outputDevices: OutputDevices) {

        Self.stopOrphanedHelpers()
        let controller = MediaController()
        self.controller = controller

        controller.onTrackInfoReceived = { [weak outputDevices] trackInfo in
            print("track \(trackInfo.payload.uniqueIdentifier) \(trackInfo.payload.title ?? "nil")")
            DispatchQueue.main.asyncAfter(deadline: .now() + 1) {
                guard let outputDevices else { return }
                outputDevices.trackDidChange(trackInfo)
            }
        }
        // main thread; the adapter reports only a helper that exited on its own, not stopListening()
        controller.onListenerTerminated = { [weak self] in
            self?.listenerTerminated()
        }
        controller.startListening()

    }

    deinit {
        controller.stopListening()
    }

    /// On quit (deinit never runs then): MediaRemoteAdapter's helper, `perl run.pl ... loop`, only
    /// writes to its pipe when a track changes, so it would run on after the app is gone.
    func stop() {
        stopped = true
        controller.stopListening()
    }

    /// Without the helper no track changes arrive and switching stops until relaunch, so start it
    /// again: after 1 s, doubling (to 60 s) while it keeps dying within 30 s of a start.
    private func listenerTerminated() {
        guard !stopped else { return }
        quickRestarts = Date().timeIntervalSince(startedAt) < 30 ? quickRestarts + 1 : 0
        let delay = min(pow(2, Double(max(quickRestarts - 1, 0))), 60)
        print("[MediaRemoteController] MediaRemoteAdapter helper exited; restarting in \(Int(delay)) s")
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, !self.stopped else { return }
            self.startedAt = Date()
            self.controller.startListening()
        }
    }

    /// A crash or kill -9 leaves the helper behind, adopted by launchd. At launch, stop those: this
    /// user's `perl .../MediaRemoteAdapter_MediaRemoteAdapter.bundle/.../run.pl ... loop` processes
    /// whose parent is launchd (pid 1). One ps at launch; nothing afterwards.
    static func stopOrphanedHelpers() {
        let ps = Process()
        ps.executableURL = URL(fileURLWithPath: "/bin/ps")
        ps.arguments = ["-x", "-o", "pid=,ppid=,command="]
        let out = Pipe()
        ps.standardOutput = out
        ps.standardError = FileHandle.nullDevice
        guard (try? ps.run()) != nil else { return }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        ps.waitUntilExit()
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ", maxSplits: 2, omittingEmptySubsequences: true)
            guard f.count == 3, let pid = Int32(f[0]), f[1] == "1" else { continue }
            let cmd = f[2]
            guard cmd.hasPrefix("/usr/bin/perl "), cmd.contains("MediaRemoteAdapter_MediaRemoteAdapter.bundle"),
                  cmd.contains("run.pl"), cmd.hasSuffix(" loop") else { continue }
            let st = kill(pid, SIGTERM)
            print("[MediaRemoteController] stopped an orphaned MediaRemoteAdapter helper, pid \(pid): \(st)")
        }
    }
    
}
