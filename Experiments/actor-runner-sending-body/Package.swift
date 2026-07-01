// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "actor-runner-sending-body",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "actor-runner-sending-body"
        )
    ]
)
