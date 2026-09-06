// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Dockit",
    platforms: [.macOS("26.0")],
    products: [
        .library(name: "DockitCore", targets: ["DockitCore"]),
        .executable(name: "DockProbe", targets: ["DockProbe"])
    ],
    targets: [
        .target(name: "DockitCore"),
        .executableTarget(
            name: "DockProbe",
            dependencies: ["DockitCore"],
            path: "Tools",
            exclude: ["FeatureLedger.mjs", "FeatureLedgerTests.mjs", "AnalyzeDockTiming.mjs", "AnalyzeDockTimingTests.mjs", "ReferenceVideo.mjs", "ReferenceVideoTests.mjs", "GenerateAppIcon.swift", "GenerateAppIconTests.swift", "MaskAppIcon.swift", "MaskAppIconTests.swift", "Release", "run-dock-probe.sh"],
            sources: ["DockProbe.swift"]
        ),
        .testTarget(name: "DockitCoreTests", dependencies: ["DockitCore"])
    ]
)
