// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "kiwiMango",
    platforms: [
        .macOS("26.0")
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm", from: "1.2.0")
    ],
    targets: [
        .executableTarget(
            name: "kiwiMango",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ],
            path: "Sources/kiwiMango",
            // Swift 6 strict concurrency floods errors from GRDB internals — pragmatic v5 mode
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
