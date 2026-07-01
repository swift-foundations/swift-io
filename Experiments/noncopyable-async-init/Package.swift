// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "noncopyable-async-init",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "noncopyable-async-init",
            swiftSettings: [
                .strictMemorySafety(),
            ]
        )
    ]
)
