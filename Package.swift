// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "AnimeGodCore",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AnimeGodCore", targets: ["AnimeGodCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0")
    ],
    targets: [
        .target(
            name: "AnimeGodCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift")]
        ),
        .testTarget(
            name: "AnimeGodCoreTests",
            dependencies: ["AnimeGodCore"]
        )
    ]
)

