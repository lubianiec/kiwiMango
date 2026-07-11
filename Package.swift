// swift-tools-version: 6.0
import PackageDescription

// km-v2 = kiwiMango Dashboard V2. Nazwa produktu zostaje "kiwiMango",
// żeby ścieżka danych (~/Library/Application Support/KiwiMango/) i Makefile
// działały bez zmian.
let package = Package(
    name: "kiwiMango",
    platforms: [
        .macOS(.v15)
    ],
    dependencies: [
        // ponytail: jedyna zależność — SwiftTerm/Yams/Metal z v1 wycięte (nieużywane w V2)
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.0.0")
    ],
    targets: [
        .executableTarget(
            name: "kiwiMango",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift")
            ],
            path: "Sources/kiwiMango",
            // Swift 6 strict concurrency zalewa błędami z wnętrza GRDB — tryb v5 jak w v1
            swiftSettings: [
                .swiftLanguageMode(.v5)
            ]
        )
    ]
)
