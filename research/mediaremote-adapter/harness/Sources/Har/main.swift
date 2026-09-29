import Foundation
import MediaRemoteAdapter
func cpu() -> Double { var u = rusage(); getrusage(RUSAGE_SELF, &u); return Double(u.ru_utime.tv_sec + u.ru_stime.tv_sec) + Double(u.ru_utime.tv_usec + u.ru_stime.tv_usec) / 1e6 }
func spin(_ s: Double) { RunLoop.main.run(until: Date().addingTimeInterval(s)) }
func helpers() -> [Int32] {
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep"); p.arguments = ["-P", "\(getpid())"]
    let o = Pipe(); p.standardOutput = o; try! p.run(); p.waitUntilExit()
    return String(decoding: o.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).split(separator: "\n").compactMap { Int32($0) }
}
let c = MediaController()
var terminated = 0
c.onListenerTerminated = { terminated += 1 }
c.startListening(); spin(1.5)
let kids = helpers(); print("1. helper pids: \(kids)")
for k in kids { kill(k, SIGKILL) }
spin(0.5); let c0 = cpu(); spin(2.0)
print(String(format: "   after kill -9: onListenerTerminated x%d, CPU over 2 s = %.3f s", terminated, cpu() - c0))
c.startListening(); spin(1.5)
print("2. restarted, helper pids: \(helpers())")
c.stopListening(); spin(2.0)
print("   after stopListening: onListenerTerminated total x\(terminated) (expect still 1), helpers left: \(helpers())")
