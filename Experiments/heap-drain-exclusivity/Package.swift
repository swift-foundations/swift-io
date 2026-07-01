// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "heap-drain-exclusivity",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "heap-drain-exclusivity",
            swiftSettings: [
                .strictMemorySafety(),
                .enableExperimentalFeature("Lifetimes"),
            ]
        )
    ]
)
