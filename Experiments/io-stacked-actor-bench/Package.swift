// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "io-stacked-actor-bench",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/swift-foundations/swift-executors.git", branch: "main"),
        .package(url: "https://github.com/swift-foundations/swift-kernel.git", branch: "main"),
        .package(url: "https://github.com/swift-primitives/swift-memory-primitives.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "bench",
            dependencies: [
                .product(name: "IO", package: "swift-io"),
                .product(name: "IO Blocking", package: "swift-io"),
                .product(name: "Executors", package: "swift-executors"),
                .product(name: "Kernel", package: "swift-kernel"),
                .product(name: "Memory Primitives", package: "swift-memory-primitives"),
            ]
        )
    ],
    swiftLanguageModes: [.v6]
)

for target in package.targets where ![.system, .binary, .plugin, .macro].contains(target.type) {
    let ecosystem: [SwiftSetting] = [
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableExperimentalFeature("Lifetimes"),
        .enableExperimentalFeature("LifetimeDependence"),
    ]
    target.swiftSettings = (target.swiftSettings ?? []) + ecosystem
}
