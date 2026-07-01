// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "do-throws-typealias-workaround",
    platforms: [.macOS(.v26)],
    dependencies: [
        .package(path: "../.."),
    ],
    targets: [
        .executableTarget(
            name: "do-throws-typealias-workaround",
            dependencies: [
                .product(name: "IO", package: "swift-io"),
            ]
        )
    ]
)
