// swift-tools-version: 6.2
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
        .executable(name: "sidekick-hook", targets: ["SidekickHook"]),
        .executable(name: "sidekick-mcp", targets: ["SidekickMCP"]),
        .executable(name: "sidekick-telemetry", targets: ["SidekickTelemetry"]),
    ],
    dependencies: [
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.13.0"),
        .package(url: "https://github.com/LebJe/TOMLKit", from: "0.5.0"),
        // Tree-sitter grammar-accurate syntax highlighting (replacing the regex
        // highlighter, starting with Swift). The grammar's `with-generated-files`
        // branch ships the generated parser.c so SwiftPM can build it.
        .package(url: "https://github.com/ChimeHQ/SwiftTreeSitter", from: "0.9.0"),
        .package(url: "https://github.com/alex-pinkus/tree-sitter-swift", branch: "with-generated-files"),
        // Go, Rust, and TypeScript link cleanly — their manifests list scanner.c
        // unconditionally (Go has none). JS/JSX/TS/TSX are all highlighted via
        // the TSX grammar (a superset), so tree-sitter-javascript isn't needed.
        .package(url: "https://github.com/tree-sitter/tree-sitter-go", from: "0.25.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-rust", from: "0.24.0"),
        .package(url: "https://github.com/tree-sitter/tree-sitter-typescript", from: "0.23.2"),
        .package(url: "https://github.com/tree-sitter-grammars/tree-sitter-markdown", branch: "split_parser"),
        // Python's official package compiles only parser.c (its manifest drops
        // scanner.c via a CWD-relative check). We depend on it for the large
        // parser.c (no repo bloat) and supply the small external scanner via the
        // local `TreeSitterPythonScanner` C target below.
        .package(url: "https://github.com/tree-sitter/tree-sitter-python", from: "0.25.0"),
    ],
    targets: [
        .target(
            name: "SidekickTelemetryCore",
            path: "Sources/SidekickTelemetryCore",
            swiftSettings: [
                .unsafeFlags(["-swift-version", "5"])
            ]
        ),
        // Supplies tree-sitter-python's external (indentation) scanner, which the
        // grammar's own SwiftPM manifest fails to compile when consumed as a
        // dependency. Just the ~15KB scanner.c + the matching tree_sitter headers
        // (vendored from v0.25.0); the multi-MB parser.c still comes from the
        // package, so this adds no meaningful repo weight.
        .target(
            name: "TreeSitterPythonScanner",
            path: "Sources/TreeSitterPythonScanner",
            sources: ["scanner.c"],
            publicHeadersPath: "include",
            cSettings: [.headerSearchPath("include")]
        ),
        .executableTarget(
            name: "Sidekick",
            dependencies: [
                "SwiftTerm",
                "TOMLKit",
                "SidekickTelemetryCore",
                .product(name: "SwiftTreeSitter", package: "SwiftTreeSitter"),
                .product(name: "TreeSitterSwift", package: "tree-sitter-swift"),
                .product(name: "TreeSitterGo", package: "tree-sitter-go"),
                .product(name: "TreeSitterRust", package: "tree-sitter-rust"),
                // One product carries both TreeSitterTypeScript and TreeSitterTSX.
                .product(name: "TreeSitterTypeScript", package: "tree-sitter-typescript"),
                // Block-level Markdown (headings, fenced code, lists, links).
                .product(name: "TreeSitterMarkdown", package: "tree-sitter-markdown"),
                // Python: parser.c from the package, external scanner from the
                // local C target (works around the package's dropped scanner.c).
                .product(name: "TreeSitterPython", package: "tree-sitter-python"),
                "TreeSitterPythonScanner",
            ],
            path: "Sources/Sidekick",
            swiftSettings: [
                // The app is overwhelmingly AppKit main-thread code, so the whole
                // module defaults to the main actor; the genuinely-background
                // types (GitService, WorktreeService, ProcessRunner, IPC value
                // types, …) are marked nonisolated/Sendable individually.
                .defaultIsolation(MainActor.self),
                .unsafeFlags(["-swift-version", "6"])
            ]
        ),
        .executableTarget(
            name: "SidekickCtl",
            path: "Sources/sidekick-ctl",
            swiftSettings: [
                .unsafeFlags(["-swift-version", "6"])
            ]
        ),
        .executableTarget(
            name: "SidekickAgentStatus",
            path: "Sources/sidekick-agent-status",
            swiftSettings: [
                .unsafeFlags(["-swift-version", "6"])
            ]
        ),
        .executableTarget(
            name: "SidekickHook",
            path: "Sources/sidekick-hook",
            swiftSettings: [
                .unsafeFlags(["-swift-version", "6"])
            ]
        ),
        .executableTarget(
            name: "SidekickMCP",
            path: "Sources/sidekick-mcp",
            swiftSettings: [
                .unsafeFlags(["-swift-version", "6"])
            ]
        ),
        .executableTarget(
            name: "SidekickTelemetry",
            dependencies: ["SidekickTelemetryCore"],
            path: "Sources/sidekick-telemetry",
            swiftSettings: [
                .unsafeFlags(["-swift-version", "6"])
            ]
        ),
        .testTarget(
            name: "SidekickTests",
            dependencies: ["Sidekick", "SidekickTelemetryCore"],
            path: "Tests/SidekickTests"
        ),
    ]
)
