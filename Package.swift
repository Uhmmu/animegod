// swift-tools-version: 6.1

import PackageDescription

let package = Package(
    name: "AnimeGodCore",
    defaultLocalization: "en",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "AnimeGodCore", targets: ["AnimeGodCore"])
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.10.0")
    ],
    targets: [
        // macOS's own libarchive, declared by hand because the SDK ships
        // the library but not its headers. Unpacking downloads in-process
        // keeps the app's security-scoped folder access, which a spawned
        // helper would not inherit.
        .target(name: "CLibArchive", linkerSettings: [.linkedLibrary("archive")]),
        .target(
            name: "AnimeGodCore",
            dependencies: [.product(name: "GRDB", package: "GRDB.swift"), "CLibArchive"],
            // User-visible core strings (display names, errors) are looked
            // up in this catalog with `bundle: .module`. Xcode compiles it;
            // command-line `swift test` copies it as is and so falls back
            // to the English keys, which is what the tests expect.
            resources: [.process("Resources")]
        ),
        .testTarget(
            name: "AnimeGodCoreTests",
            dependencies: ["AnimeGodCore"]
        )
    ]
)

