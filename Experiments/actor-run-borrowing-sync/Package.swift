// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "actor-run-borrowing-sync",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(name: "test")
    ]
)
