// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "Sidekick",
    platforms: [
        .macOS(.v13)
    ],
    products: [
        .executable(name: "Sidekick", targets: ["Sidekick"]),
        .executable(name: "sidekick-ctl", targets: ["SidekickCtl"]),
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
            path: "Sources/Sidekick"
        ),
        .executableTarget(
            name: "SidekickCtl",
            path: "Sources/SidekickCtl"
        ),
    ]
)