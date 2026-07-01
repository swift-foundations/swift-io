// swift-tools-version: 6.3.1

import PackageDescription

let package = Package(
    name: "swift-io",
    platforms: [
        .macOS(.v26),
        .iOS(.v26),
        .tvOS(.v26),
        .watchOS(.v26),
        .visionOS(.v26)
    ],
    products: [
        .library(name: "IO", targets: ["IO"]),
        .library(name: "IO Events", targets: ["IO Events"]),
        .library(name: "IO Completions", targets: ["IO Completions"]),
        .library(name: "IO Test Support", targets: ["IO Test Support"]),
        .library(name: "IO Completions Test Support", targets: ["IO Completions Test Support"]),
    ],
    dependencies: [
        .package(url: "https://github.com/swift-foundations/swift-kernel.git", branch: "main"),
        .package(url: "https://github.com/swift-foundations/swift-async.git", branch: "main"),
        .package(url: "https://github.com/swift-foundations/swift-executors.git", branch: "main"),
        .package(url: "https://github.com/swift-foundations/swift-threads.git", branch: "main"),
        .package(url: "https://github.com/swift-foundations/swift-synchronizers.git", branch: "main"),
        .package(url: "https://github.com/swift-primitives/swift-io-primitives.git", branch: "main"),
        .package(url: "https://github.com/swift-primitives/swift-buffer-primitives.git", branch: "main"),
        .package(url: "https://github.com/swift-primitives/swift-hash-primitives.git", branch: "main"),
        .package(url: "https://github.com/swift-primitives/swift-heap-primitives.git", branch: "main"),
        .package(url: "https://github.com/swift-primitives/swift-dictionary-primitives.git", branch: "main"),
        .package(url: "https://github.com/swift-primitives/swift-hash-table-primitives.git", branch: "main"),
        .package(url: "https://github.com/swift-primitives/swift-buffer-linear-primitives.git", branch: "main"),
        .package(url: "https://github.com/swift-primitives/swift-storage-primitives.git", branch: "main"),
        .package(url: "https://github.com/swift-primitives/swift-memory-heap-primitives.git", branch: "main"),
        .package(url: "https://github.com/swift-primitives/swift-memory-allocation-primitives.git", branch: "main"),
        .package(url: "https://github.com/swift-primitives/swift-memory-primitives.git", branch: "main"),
        .package(url: "https://github.com/swift-primitives/swift-span-primitives.git", branch: "main"),
        .package(url: "https://github.com/swift-primitives/swift-either-primitives.git", branch: "main"),
        .package(url: "https://github.com/swift-primitives/swift-witness-primitives.git", branch: "main"),
        .package(url: "https://github.com/swift-foundations/swift-witnesses.git", branch: "main"),
    ],
    targets: [

        // MARK: - Events (strategy-only, domain-agnostic reactor)

        .target(
            name: "IO Events",
            dependencies: [
                .product(name: "Kernel", package: "swift-kernel"),
                .product(name: "IO Primitives", package: "swift-io-primitives"),
                .product(name: "Executors", package: "swift-executors"),
                .product(name: "Async", package: "swift-async"),
                .product(name: "Hash Primitives", package: "swift-hash-primitives"),
                .product(name: "Heap Primitive", package: "swift-heap-primitives"),
                .product(name: "Buffer Primitives", package: "swift-buffer-primitives"),
                .product(name: "Memory Primitives", package: "swift-memory-primitives"),
                .product(name: "Dictionary Primitives", package: "swift-dictionary-primitives"),
                .product(name: "Witness Primitives", package: "swift-witness-primitives"),
                .product(name: "Witnesses", package: "swift-witnesses"),
                .product(name: "Either Primitives", package: "swift-either-primitives"),
            ]
        ),

        // MARK: - Completions (strategy-only, domain-agnostic proactor)

        .target(
            name: "IO Completions",
            dependencies: [
                .product(name: "Kernel", package: "swift-kernel"),
                .product(name: "Kernel Completion", package: "swift-kernel"),
                .product(name: "IO Primitives", package: "swift-io-primitives"),
                .product(name: "Executors", package: "swift-executors"),
                .product(name: "Async", package: "swift-async"),
                .product(name: "Memory Primitives", package: "swift-memory-primitives"),
                .product(name: "Dictionary Primitives", package: "swift-dictionary-primitives"),
                .product(name: "Hash Indexed Primitive", package: "swift-hash-table-primitives"),
                .product(name: "Hash Tagged Primitives", package: "swift-hash-primitives"),
                .product(name: "Buffer Primitive", package: "swift-buffer-primitives"),
                .product(name: "Buffer Linear Primitive", package: "swift-buffer-linear-primitives"),
                .product(name: "Buffer Linear Primitives", package: "swift-buffer-linear-primitives"),
                .product(name: "Storage Primitive", package: "swift-storage-primitives"),
                .product(name: "Storage Contiguous Primitives", package: "swift-storage-primitives"),
                .product(name: "Memory Heap Primitives", package: "swift-memory-heap-primitives"),
                .product(name: "Memory Allocator Primitive", package: "swift-memory-allocation-primitives"),
                .product(name: "Synchronizer Blocking", package: "swift-synchronizers"),
            ]
        ),

        // MARK: - Umbrella (strategies + host-adaptive selector)

        .target(
            name: "IO",
            dependencies: [
                "IO Events",
                "IO Completions",
                .product(name: "Kernel", package: "swift-kernel"),
                .product(name: "IO Primitives", package: "swift-io-primitives"),
                .product(name: "Either Primitives", package: "swift-either-primitives"),
            ]
        ),

        // MARK: - Test Support (hosts the Basic domain — consumed only by tests)
        //
        // Basic.Capabilities + Basic.Error + Kernel.Thread.Actor+Basic
        // syscall extensions + per-strategy factories live here so the
        // production surface of swift-io remains strategy-only. Downstream
        // production packages (swift-file-system, swift-sockets,
        // swift-server) define their own domain Capabilities.

        .target(
            name: "IO Test Support",
            dependencies: [
                .product(name: "Span Raw Primitives", package: "swift-span-primitives"),
                "IO",
                .product(name: "Kernel", package: "swift-kernel"),
                .product(name: "Kernel Test Support", package: "swift-kernel"),
                .product(name: "IO Primitives", package: "swift-io-primitives"),
                .product(name: "Thread Actor", package: "swift-threads"),
                .product(name: "Executors", package: "swift-executors"),
                .product(name: "Buffer Primitives", package: "swift-buffer-primitives"),
                .product(name: "Memory Primitives", package: "swift-memory-primitives"),
            ],
            path: "Tests/Support"
        ),

        .target(
            name: "IO Completions Test Support",
            dependencies: [
                "IO Completions",
                "IO Events",
                "IO Test Support",
                .product(name: "Synchronizer Blocking", package: "swift-synchronizers"),
            ],
            path: "Tests/Completions Support"
        ),

        // MARK: - Tests

        .testTarget(
            name: "IO Basic Tests",
            dependencies: [
                "IO Test Support",
            ],
            path: "Tests/IO Blocking Tests"
        ),
        .testTarget(
            name: "IO Events Tests",
            dependencies: [
                "IO Events",
                "IO Test Support",
                .product(name: "Heap Primitive", package: "swift-heap-primitives"),
            ]
        ),
        .testTarget(
            name: "IO Completions Tests",
            dependencies: [
                "IO Completions",
                "IO Completions Test Support",
            ]
        ),
        .testTarget(
            name: "IO Tests",
            dependencies: [
                "IO",
                "IO Test Support",
            ]
        ),
        // Benchmarks moved to Benchmarks/io-bench/ (nested package with swift-testing .timed())
        // Run: cd Benchmarks/io-bench && swift test
    ]
)

for target in package.targets where ![.system, .binary, .plugin, .macro].contains(target.type) {
    let ecosystem: [SwiftSetting] = [
        .strictMemorySafety(),
        .enableUpcomingFeature("ExistentialAny"),
        .enableUpcomingFeature("InternalImportsByDefault"),
        .enableUpcomingFeature("MemberImportVisibility"),
        .enableUpcomingFeature("NonisolatedNonsendingByDefault"),
        .enableExperimentalFeature("LifetimeDependence"),
        .enableExperimentalFeature("Lifetimes"),
        .enableExperimentalFeature("SuppressedAssociatedTypes"),
        .enableUpcomingFeature("InferIsolatedConformances"),
        .enableUpcomingFeature("LifetimeDependence"),
    ]

    let package: [SwiftSetting] = []

    target.swiftSettings = (target.swiftSettings ?? []) + ecosystem + package
}
