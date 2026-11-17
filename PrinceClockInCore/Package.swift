// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "PrinceClockInCore",
    platforms: [.macOS(.v26)],
    products: [
        .library(name: "PrinceClockInCore", targets: ["PrinceClockInCore"])
    ],
    targets: [
        .target(name: "PrinceClockInCore", swiftSettings: [.swiftLanguageMode(.v6)]),
        .testTarget(name: "PrinceClockInCoreTests", dependencies: ["PrinceClockInCore"])
    ]
)
