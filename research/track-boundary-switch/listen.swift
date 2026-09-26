// Prints com.apple.Music.playerInfo distributed notifications for N seconds.
import Foundation
let n = DistributedNotificationCenter.default()
n.addObserver(forName: NSNotification.Name("com.apple.Music.playerInfo"), object: nil, queue: .main) { note in
    print(Date(), (note.userInfo ?? [:]).map { "\($0.key)=\($0.value) (\(type(of: $0.value)))" }.sorted().joined(separator: "\n  "), "\n---")
}
RunLoop.main.run(until: Date().addingTimeInterval(Double(CommandLine.arguments.dropFirst().first ?? "10")!))
