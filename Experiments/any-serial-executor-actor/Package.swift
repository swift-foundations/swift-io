// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "any-serial-executor-actor",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "test", path: "Sources/test")
    ]
)
