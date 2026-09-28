// swift-tools-version:5.9
// Compile-only check of the app's Swift sources without Xcode. Pins match Package.resolved.
// Run: cd research/typecheck && ./check.sh
import PackageDescription

let package = Package(
    name: "LosslessSwitcherTypecheck",
    platforms: [.macOS("15.0")], // the app target is 15.0; RendererEngine needs process taps (14.2)
    dependencies: [
        .package(url: "https://github.com/rnine/SimplyCoreAudio.git", revision: "343d463cffef1f30458d02ce2dc441138e9e0134"),
        .package(url: "https://github.com/JohnSundell/Sweep.git", exact: "0.4.0"),
        .package(url: "https://github.com/PrivateFrameworks/MediaRemote", exact: "0.1.0"),
        .package(url: "https://github.com/ejbills/mediaremote-adapter", revision: "70bff25eb1e88ffcb993389f6a0eda2a3516565f"),
    ],
    targets: [
        .executableTarget(
            name: "LosslessSwitcher",
            dependencies: [
                "SimplyCoreAudio", "Sweep",
                .product(name: "PrivateMediaRemote", package: "MediaRemote"),
                .product(name: "MediaRemoteAdapter", package: "mediaremote-adapter"),
            ],
            path: "Sources/LosslessSwitcher",
            linkerSettings: [.unsafeFlags(["-F", "/System/Library/PrivateFrameworks", "-framework", "MediaRemote"])]
        ),
    ]
)
