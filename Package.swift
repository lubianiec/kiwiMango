// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kiwiMango",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0"),
        // `swift build` (what the Makefile uses) does NOT reliably compile
        // .metal → default.metallib the way Xcode does — verified empirically
        // (see PLAN.md F9.0): with plain SwiftPM, .metal files are just copied
        // as raw resources, never handed to the Metal compiler. This plugin
        // does that compilation step explicitly, producing `debug.metallib`.
        .package(url: "https://github.com/schwa/MetalCompilerPlugin", from: "0.1.6")
    ],
    targets: [
        .executableTarget(
            name: "kiwiMango",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/kiwiMango",
            // .metal files aren't auto-detected by SwiftPM's default resource
            // scan — declaring them explicitly silences the warning. The actual
            // compiled shader library comes from MetalCompilerPlugin below.
            resources: [
                .process("Shaders"),
                // Bundled offline (F26.9) so Mermaid diagrams render with zero
                // network access, matching the rest of the UI's no-CDN policy.
                .copy("Resources/mermaid.min.js")
            ],
            // Swift 6 strict concurrency floods errors from GRDB internals — pragmatic v5 mode
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ],
            plugins: [
                .plugin(name: "MetalCompilerPlugin", package: "MetalCompilerPlugin")
            ]
        )
    ]
)
