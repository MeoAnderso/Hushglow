// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DisplayKeys",
    platforms: [.macOS("26.0")],
    targets: [
        // Pure logic with no AppKit or IOKit dependency, so it is unit-testable.
        .target(name: "DisplayKeysCore"),
        .executableTarget(name: "DisplayKeys", dependencies: ["DisplayKeysCore"]),
        .testTarget(name: "DisplayKeysCoreTests", dependencies: ["DisplayKeysCore"]),
        .testTarget(name: "DisplayKeysTests", dependencies: ["DisplayKeys", "DisplayKeysCore"]),
    ]
)
