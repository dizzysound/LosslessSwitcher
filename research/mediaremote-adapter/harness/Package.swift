// swift-tools-version:5.9
// Kills MediaRemoteAdapter's perl helper and measures CPU and onListenerTerminated calls.
// Run: swift run. To compare the old pin, change revision to 70bff25eb1e88ffcb993389f6a0eda2a3516565f
// (and the URL to https://github.com/ejbills/mediaremote-adapter).
import PackageDescription
let package = Package(name: "Har", platforms: [.macOS("15.0")],
  dependencies: [.package(url: "https://github.com/dizzysound/mediaremote-adapter", revision: "2e59752c337a66c532b5e70082427b09a8d63759")],
  targets: [.executableTarget(name: "Har", dependencies: [.product(name: "MediaRemoteAdapter", package: "mediaremote-adapter")], path: "Sources/Har")])
