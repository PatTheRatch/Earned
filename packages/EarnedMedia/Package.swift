// swift-tools-version: 6.0
import PackageDescription

// Apple platforms only, deliberately: this package exists to wrap ImageIO,
// which is exactly the dependency EarnedKit's charter forbids. Keeping the
// avatar pipeline here keeps the domain engine buildable on Linux and keeps
// this code testable with a plain `swift test` on a Mac.
let package = Package(
    name: "EarnedMedia",
    platforms: [.iOS(.v17), .macOS(.v14)],
    products: [
        .library(name: "EarnedMedia", targets: ["EarnedMedia"])
    ],
    targets: [
        .target(name: "EarnedMedia"),
        .testTarget(name: "EarnedMediaTests", dependencies: ["EarnedMedia"]),
    ]
)
