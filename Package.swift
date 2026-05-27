// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Sidekick",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Sidekick", targets: ["Sidekick"]),
        .executable(name: "sidekick-ctl", targets: ["SidekickCtl"]),
        .executable(name: "sidekick-agent-status", targets: ["SidekickAgentStatus"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.13.0"),
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.5.0"),
    ],
    targets: [
        .executableTarget(
            name: "Sidekick",
            dependencies: [
                "SwiftTerm",
                "TOMLKit",
            ],
            path: "Sources/Sidekick",
            swiftSettings: [
                .enableUpcomingFeature("BareSlashRegexLiterals"),
                .unsafeFlags(["-swift-version", "5"])
            ]
        ),
        .executableTarget(
            name: "SidekickCtl",
            path: "Sources/sidekick-ctl",
            swiftSettings: [
                .unsafeFlags(["-swift-version", "5"])
            ]
        ),
        .executableTarget(
            name: "SidekickAgentStatus",
            path: "Sources/sidekick-agent-status",
            swiftSettings: [
                .unsafeFlags(["-swift-version", "5"])
            ]
        ),
        .testTarget(
            name: "SidekickTests",
            dependencies: ["Sidekick"],
            path: "Tests/SidekickTests"
        ),
    ]
)
