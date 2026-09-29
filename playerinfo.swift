// playerinfo <seconds>: logs Music's com.apple.Music.playerInfo distributed notifications.
import Foundation
setvbuf(stdout, nil, _IOLBF, 0)
let t0 = Date(); let df = DateFormatter(); df.dateFormat = "HH:mm:ss.SSS"; func wall() -> String { df.string(from: Date()) }
DistributedNotificationCenter.default().addObserver(forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { n in
    let u = n.userInfo ?? [:]
    print(wall() + " " + "\(u["Player State"] ?? "?") | \(u["Name"] ?? "?") | PersistentID \(u["PersistentID"] ?? "?") | keys \(u.keys.map { "\($0)" }.sorted().joined(separator: ","))")
}
RunLoop.main.run(until: Date().addingTimeInterval(Double(CommandLine.arguments[1])!))
