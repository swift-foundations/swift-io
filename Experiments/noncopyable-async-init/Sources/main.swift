// MARK: - ~Copyable Async Throws Init
// Purpose: Verify that ~Copyable structs can have async throws initializers
//          in Swift 6.3, eliminating the need for static factory methods
// Hypothesis: A ~Copyable struct can define `init(...) async throws(E)`
//             and be constructed directly without a static factory
//
// Toolchain: Xcode / Swift 6.3 (swiftlang-6.3.0.123.5)
// Platform: macOS 26 (arm64)
//
// Result: CONFIRMED — all 5 variants compile and run correctly
// Date: 2026-04-03

// MARK: - Variant 1: Basic async init on ~Copyable struct
// Hypothesis: `init() async` compiles on ~Copyable struct
// Result: CONFIRMED

struct Resource1: ~Copyable {
    let value: Int

    init() async {
        value = await Self.fetchValue()
    }

    static func fetchValue() async -> Int { 42 }

    consuming func close() { }
}

// MARK: - Variant 2: Async throws init with typed error
// Hypothesis: `init() async throws(E)` compiles on ~Copyable struct
// Result: CONFIRMED

enum SetupError: Error { case failed }

struct Resource2: ~Copyable {
    let value: Int

    init(shouldFail: Bool) async throws(SetupError) {
        if shouldFail { throw .failed }
        value = await Self.fetchValue()
    }

    static func fetchValue() async -> Int { 42 }

    consuming func close() { }
}

// MARK: - Variant 3: Sendable + ~Copyable with async throws init
// Hypothesis: Adding Sendable doesn't break async init on ~Copyable
// Result: CONFIRMED

struct Resource3: ~Copyable, Sendable {
    let value: Int

    init() async throws(SetupError) {
        value = await Self.fetchValue()
    }

    static func fetchValue() async -> Int { 42 }

    consuming func close() { }
}

// MARK: - Variant 4: Init that takes ~Copyable parameter
// Hypothesis: async init can consume a ~Copyable parameter
// Result: CONFIRMED

struct Descriptor: ~Copyable {
    let raw: Int32
}

struct Resource4: ~Copyable, Sendable {
    let fd: Int32

    init(_ descriptor: consuming Descriptor) async throws(SetupError) {
        fd = descriptor.raw
        // Simulate async registration
        _ = await Self.register(fd)
    }

    static func register(_ fd: Int32) async -> Bool { true }

    consuming func close() { }
}

// MARK: - Variant 5: Init returning from withCheckedContinuation
// Hypothesis: async init can use withCheckedContinuation internally
// Result: CONFIRMED
// Revalidated: Swift 6.3.1 (2026-04-30) — PASSES

struct Resource5: ~Copyable, Sendable {
    let id: Int

    init() async {
        id = await withCheckedContinuation { continuation in
            continuation.resume(returning: 99)
        }
    }

    consuming func close() { }
}

// MARK: - Execution

@main
struct Main {
    static func main() async throws {
        // V1
        let r1 = await Resource1()
        print("V1: value = \(r1.value)")
        r1.close()

        // V2
        let r2 = try await Resource2(shouldFail: false)
        print("V2: value = \(r2.value)")
        r2.close()

        // V3
        let r3 = try await Resource3()
        print("V3: value = \(r3.value)")
        r3.close()

        // V4
        let r4 = try await Resource4(Descriptor(raw: 42))
        print("V4: fd = \(r4.fd)")
        r4.close()

        // V5
        let r5 = await Resource5()
        print("V5: id = \(r5.id)")
        r5.close()

        print("All variants passed")
    }
}
