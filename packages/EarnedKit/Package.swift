// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "EarnedKit",
    products: [
        .library(name: "EarnedKit", targets: ["EarnedKit"])
    ],
    targets: [
        .target(name: "EarnedKit"),
        .testTarget(name: "EarnedKitTests", dependencies: ["EarnedKit"]),
    ]
)
