// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "actor-borrowing-async",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "test")
    ]
)
