// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "sync-async-overload-disambiguation",
    platforms: [.macOS(.v26)],
    targets: [
        .executableTarget(
            name: "sync-async-overload-disambiguation"
        )
    ]
)
