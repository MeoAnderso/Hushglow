// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "DisplayKeys",
    platforms: [.macOS("26.0")],
    dependencies: [
        // The updater: the one dependency, at an exact version so that every build has the same.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        // Pure logic with no AppKit or IOKit dependency, so it is unit-testable.
        .target(name: "DisplayKeysCore"),
        .executableTarget(
            name: "DisplayKeys",
            dependencies: ["DisplayKeysCore", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "DisplayKeysCoreTests", dependencies: ["DisplayKeysCore"]),
        .testTarget(name: "DisplayKeysTests", dependencies: ["DisplayKeys", "DisplayKeysCore"]),
    ]
)
