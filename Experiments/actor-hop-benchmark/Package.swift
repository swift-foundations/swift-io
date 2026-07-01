// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "actor-hop-benchmark",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/swift-foundations/swift-executors.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "bench",
            dependencies: [
                .product(name: "Executors", package: "swift-executors"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)
