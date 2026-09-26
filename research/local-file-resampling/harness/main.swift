// Standalone harness for Quality/LocalTrack.swift (the full app needs Xcode + SPM packages).
import Foundation
struct CMPlayerStats { let sampleRate: Double; let bitDepth: Int; let date: Date; let priority: Int }
let args = CommandLine.arguments.dropFirst()
if args.isEmpty {
    print("current:", LocalTrack.currentStats().map { "\($0.sampleRate) Hz / \($0.bitDepth) bit" } ?? "nil")
} else {
    for p in args { print(p, "->", LocalTrack.readFormat(url: URL(fileURLWithPath: p)).map { "\($0.sampleRate) Hz / \($0.bitDepth) bit" } ?? "nil") }
}
