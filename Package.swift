// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notcher",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Notcher", targets: ["Notcher"]),
        .library(name: "LinkCore", targets: ["LinkCore"]),
        .library(name: "NotcherKit", targets: ["NotcherKit"]),
    ],
    targets: [
        .target(
            name: "LinkCore",
            path: "Sources/LinkCore"
        ),
        .target(
            name: "NotcherKit",
            dependencies: ["LinkCore"],
            path: "Sources/NotcherKit"
        ),
        .executableTarget(
            name: "Notcher",
            dependencies: ["NotcherKit", "LinkCore"],
            path: "Sources/Notcher"
        ),
        // Offscreen snapshot harness for visual inspection (renders the real
        // island states to PNG; screencapture is permission-gated in dev).
        .executableTarget(
            name: "IslandSnapshot",
            dependencies: ["NotcherKit", "LinkCore"],
            path: "Snapshot"
        ),
        // Dev probe (never bundled): drives the LIVE app over Bonjour and
        // stress-tests real windows/engines in-process. See Probe/README.
        .executableTarget(
            name: "NotcherProbe",
            dependencies: ["NotcherKit", "LinkCore"],
            path: "Probe"
        ),
        // Self-test harness (plain executable: CLT ships neither XCTest nor
        // the swift-testing macro plugin, so `swift test` cannot link here).
        .executableTarget(
            name: "LinkSelfTest",
            dependencies: ["LinkCore"],
            path: "SelfTest"
        ),
    ]
)
