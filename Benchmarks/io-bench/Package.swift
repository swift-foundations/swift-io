// swift-tools-version: 6.3.1

import PackageDescription

let package = Package(
    name: "io-bench",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(path: "../.."),
        .package(url: "https://github.com/swift-foundations/swift-executors.git", branch: "main"),
        .package(url: "https://github.com/swift-foundations/swift-testing.git", branch: "main"),
    ],
    targets: [
        .testTarget(
            name: "IO Performance Tests",
            dependencies: [
                .product(name: "IO", package: "swift-io"),
                .product(name: "Executors", package: "swift-executors"),
                .product(name: "IO Test Support", package: "swift-io"),
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "IO Performance Tests"
        ),
    ],
    swiftLanguageModes: [.v6]
)

for target in package.targets where ![.system, .binary, .plugin, .macro].contains(target.type) {
    let ecosystem: [SwiftSetting] = [
        .strictMemorySafety(),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableExperimentalFeature("Lifetimes"),
        .enableExperimentalFeature("SuppressedAssociatedTypes"),
    ]

    let package: [SwiftSetting] = []

    target.swiftSettings = (target.swiftSettings ?? []) + ecosystem + package
}
