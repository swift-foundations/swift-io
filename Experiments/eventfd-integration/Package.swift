// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "eventfd-integration",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(url: "https://github.com/swift-linux-foundation/swift-linux-standard.git", branch: "main"),
    ],
    targets: [
        .executableTarget(
            name: "eventfd-integration",
            dependencies: [
                .product(name: "Linux Kernel IO Standard", package: "swift-linux-standard"),
                .product(name: "Linux Kernel Event Standard", package: "swift-linux-standard"),
            ]
        )
    ]
)
