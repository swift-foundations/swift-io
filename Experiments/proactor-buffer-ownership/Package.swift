// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "proactor-buffer-ownership",
    platforms: [.macOS(.v26)],
    targets: [
        .target(
            name: "CUring",
            publicHeadersPath: "include",
            cSettings: [
                .headerSearchPath("include"),
            ],
            linkerSettings: [
                .linkedLibrary("uring", .when(platforms: [.linux])),
            ]
        ),
        .executableTarget(
            name: "experiment",
            dependencies: ["CUring"]
        ),
    ],
    swiftLanguageModes: [.v5]
)
