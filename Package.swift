// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Hushglow",
    platforms: [.macOS("26.0")],
    dependencies: [
        // The updater: the one dependency, at an exact version so that every build has the same.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0")
    ],
    targets: [
        // Pure logic with no AppKit or IOKit dependency, so it is unit-testable.
        .target(name: "HushglowCore"),
        .executableTarget(
            name: "Hushglow",
            dependencies: ["HushglowCore", .product(name: "Sparkle", package: "Sparkle")]),
        .testTarget(name: "HushglowCoreTests", dependencies: ["HushglowCore"]),
        .testTarget(name: "HushglowTests", dependencies: ["Hushglow", "HushglowCore"]),
    ]
)
