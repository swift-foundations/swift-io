// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "tilde-sendable-thread-confined",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "tilde-sendable-thread-confined",
            swiftSettings: [
                .enableExperimentalFeature("TildeSendable"),
            ]
        )
    ]
)
