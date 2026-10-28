// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "cubi",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "CubiKit", targets: ["CubiKit"]),
        .executable(name: "cubi", targets: ["cubi"]),
        .executable(name: "cubi-hook", targets: ["cubi-hook"]),
    ],
    targets: [
        // Pure logic: event models, session state machine, settings-file writer, plugin protocol.
        .target(
            name: "CubiKit",
            path: "Sources/CubiKit"
        ),
        // The menubar + notch app. AppKit top-level entry, SwiftUI only inside NSHostingView.
        .executableTarget(
            name: "cubi",
            dependencies: ["CubiKit"],
            path: "Sources/cubi",
            resources: [.copy("Resources")]
        ),
        // The hook relay Claude Code runs on every event. Darwin only: no Foundation, no JSON parsing.
        .executableTarget(
            name: "cubi-hook",
            path: "Sources/cubi-hook"
        ),
        .testTarget(
            name: "CubiKitTests",
            dependencies: ["CubiKit"],
            path: "Tests/CubiKitTests",
            resources: [.copy("Fixtures")]
        ),
    ],
    swiftLanguageModes: [.v6]
)
