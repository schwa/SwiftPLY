// swift-tools-version: 6.2

import PackageDescription

let package = Package(
    name: "SwiftPLY",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .visionOS(.v26)
    ],
    products: [
        .library(name: "SwiftPLY", targets: ["SwiftPLY"]),
        .library(name: "SwiftPLYStructs", targets: ["SwiftPLYStructs"]),
        .library(name: "SwiftPLYMetal", targets: ["SwiftPLYMetal"])
    ],
    targets: [
        .target(name: "SwiftPLY"),
        // Opt-in: uses Swift runtime functions that are not public API.
        .target(name: "SwiftPLYStructs", dependencies: ["SwiftPLY"]),
        .testTarget(name: "SwiftPLYStructsTests", dependencies: ["SwiftPLYStructs"]),
        // Opt-in: structure definitions from Metal and Model I/O vertex descriptors.
        .target(name: "SwiftPLYMetal", dependencies: ["SwiftPLY"]),
        .testTarget(name: "SwiftPLYMetalTests", dependencies: ["SwiftPLYMetal"]),
        // Loading benchmarks. Run a Release build: SwiftPLYBenchmark [repeats] [scale].
        .executableTarget(name: "SwiftPLYBenchmark", dependencies: ["SwiftPLY", "SwiftPLYStructs"]),
        .testTarget(
            name: "SwiftPLYTests",
            dependencies: ["SwiftPLY"],
            resources: [.copy("Fixtures")]
        )
    ]
)
