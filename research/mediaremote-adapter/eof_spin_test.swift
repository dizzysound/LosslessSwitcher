import Foundation
for fix in [false, true] {
    let pipe = Pipe(); var calls = 0; let lock = NSLock()
    pipe.fileHandleForReading.readabilityHandler = { h in
        let d = h.availableData
        lock.lock(); calls += 1; lock.unlock()
        if d.isEmpty { if fix { h.readabilityHandler = nil }; return }
    }
    pipe.fileHandleForWriting.write("hello\n".data(using: .utf8)!)
    try! pipe.fileHandleForWriting.close()
    let t0 = clock()
    Thread.sleep(forTimeInterval: 1.0)
    let cpu = Double(clock() - t0) / Double(CLOCKS_PER_SEC)
    lock.lock(); print("\(fix ? "fixed  " : "pinned "): handler calls in 1 s after EOF = \(calls), process CPU \(String(format: "%.2f", cpu)) s"); lock.unlock()
    pipe.fileHandleForReading.readabilityHandler = nil
}
