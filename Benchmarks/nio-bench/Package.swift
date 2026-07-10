// swift-tools-version: 6.3.3

import PackageDescription

let package = Package(
    name: "nio-bench",
    platforms: [
        .macOS(.v26),
    ],
    dependencies: [
        .package(url: "https://github.com/apple/swift-nio.git", from: "2.65.0"),
        .package(url: "https://github.com/swift-foundations/swift-testing.git", branch: "main"),
    ],
    targets: [
        .testTarget(
            name: "NIO Performance Tests",
            dependencies: [
                .product(name: "NIOPosix", package: "swift-nio"),
                .product(name: "NIOCore", package: "swift-nio"),
                .product(name: "Testing", package: "swift-testing"),
            ],
            path: "NIO Performance Tests"
        ),
    ],
    swiftLanguageModes: [.v6]
)

for target in package.targets where ![.system, .binary, .plugin, .macro].contains(target.type) {
    let ecosystem: [SwiftSetting] = [
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
    ]

    target.swiftSettings = (target.swiftSettings ?? []) + ecosystem
}
