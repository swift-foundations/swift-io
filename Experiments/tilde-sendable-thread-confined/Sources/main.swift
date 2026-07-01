// MARK: - ~Sendable for Thread-Confined Types (SE-0518)
//
// Purpose: Verify that `~Sendable` compiles for thread-confined classes,
//   matching the IO.Completion.IOUring.Ring and IO.Completion.IOCP.State
//   pattern — classes that are only accessed on a single thread (poll thread)
//   and should NOT be sendable.
//
// Hypothesis: A `final class: ~Sendable` compiles with the TildeSendable
//   experimental feature. The compiler rejects passing it across isolation
//   boundaries. This replaces `@unchecked Sendable` (which lies about safety)
//   with `~Sendable` (which tells the truth).
//
// Toolchain: Apple Swift version 6.3 (swiftlang-6.3.0.123.5 clang-2100.0.123.102)
// Status: SUPERSEDED 2026-04-30 — TildeSendable experimental feature was removed from Swift between authoring and 6.3.1; experiment cannot be exercised against current toolchain
// Revalidated: Swift 6.3.1 (2026-04-30) — STILL PRESENT (deep API drift; SUPERSEDED per [META-007])
// Platform: macOS 26.0 (arm64)
//
// Result: CONFIRMED — ~Sendable compiles on Swift 6.4-dev. Requires TildeSendable
//   experimental feature (not available in production Swift 6.3).
//
//   V1: Basic ~Sendable class                    — CONFIRMED (compiles)
//   V2: Init and mutation                        — CONFIRMED (works)
//   V3: Task capture                             — ALLOWED (region analysis proves safety)
//   V4: Actor argument                           — ALLOWED (region analysis proves safety)
//   V5: Unmanaged pointer recovery               — CONFIRMED (works)
//   V6: Struct ~Sendable                         — CONFIRMED (compiles)
//   V7: Sendable container with ~Sendable field  — REJECTED (correct: non-Sendable stored property)
//   V8: IOUring.Ring shape                       — CONFIRMED (compiles and runs)
//
//   Key finding: ~Sendable does NOT prevent all cross-isolation use. The compiler
//   uses region analysis to allow safe transfers (V3, V4). It DOES prevent
//   storing in Sendable containers (V7). This is the correct semantics — "no
//   Sendable conformance" ≠ "never crosses boundaries." The compiler proves
//   safety case-by-case via regions.
//
//   Blocker: TildeSendable is experimental-only. Cannot enable in production
//   Swift 6.3 ("experimental feature cannot be enabled in production compiler").
//   Available in Swift 6.4-dev (LLVM a3655ee8d8c4d74, Swift d13cbbfd336f246).
// Date: 2026-03-31

// ============================================================================
// MARK: - V1: Basic ~Sendable class
//
// Hypothesis: A final class can opt out of Sendable with ~Sendable.
// Result: (pending)
// ============================================================================

final class ThreadConfinedState: ~Sendable {
    var counter: Int = 0
    var registry: [String: Int] = [:]

    func increment() {
        counter += 1
    }
}

// ============================================================================
// MARK: - V2: ~Sendable class with init and mutation
//
// Hypothesis: ~Sendable classes can be created and mutated on a single thread.
// Result: (pending)
// ============================================================================

func testV2() {
    let state = ThreadConfinedState()
    state.increment()
    state.registry["test"] = 42
    print("V2: counter=\(state.counter), registry=\(state.registry)")
}

// ============================================================================
// MARK: - V3: ~Sendable prevents Task capture
//
// Hypothesis: Capturing a ~Sendable value in a Task should be rejected
//   because Task closures are @Sendable.
// Result: (pending)
// ============================================================================

func testV3() {
    let state = ThreadConfinedState()
    Task {
        state.increment()  // Should error: capture of ~Sendable in @Sendable closure
    }
}

// ============================================================================
// MARK: - V4: ~Sendable prevents actor method argument
//
// Hypothesis: Passing a ~Sendable value to an actor method should be rejected.
// Result: (pending)
// ============================================================================

actor Worker {
    func process(_ state: ThreadConfinedState) {
        state.increment()
    }
}

func testV4() async {
    let worker = Worker()
    let state = ThreadConfinedState()
    await worker.process(state)  // Should error: passing ~Sendable to actor
}

// ============================================================================
// MARK: - V5: ~Sendable with Unmanaged (IOUring.Ring pattern)
//
// Hypothesis: ~Sendable classes can still be used with Unmanaged for
//   raw pointer recovery — the poll thread pattern stores the class as
//   an Unmanaged pointer and recovers it on the same thread.
// Result: (pending)
// ============================================================================

func testV5() {
    let state = ThreadConfinedState()
    state.counter = 10

    // Store as unmanaged (simulates Handle.ringPtr pattern)
    let unmanaged = Unmanaged.passRetained(state)
    let ptr = unmanaged.toOpaque()

    // Recover on "same thread" (simulates poll thread recovery)
    let recovered = Unmanaged<ThreadConfinedState>.fromOpaque(ptr).takeRetainedValue()
    print("V5: recovered counter=\(recovered.counter)")
}

// ============================================================================
// MARK: - V6: Struct with ~Sendable (IOCP.State alternative)
//
// Hypothesis: A struct can also be ~Sendable. Tests whether the feature
//   works for value types too.
// Result: (pending)
// ============================================================================

struct ThreadConfinedValue: ~Sendable {
    var data: [Int] = []
    mutating func append(_ value: Int) {
        data.append(value)
    }
}

func testV6() {
    var value = ThreadConfinedValue()
    value.append(1)
    value.append(2)
    print("V6: data=\(value.data)")
}

// ============================================================================
// MARK: - V7: ~Sendable class stored in Sendable container
//
// Hypothesis: A Sendable struct that stores a ~Sendable class should be
//   rejected — the container can't be Sendable if its contents aren't.
// Result: (pending)
// ============================================================================

// V7: CONFIRMED — correctly rejected:
// error: stored property 'state' of 'Sendable'-conforming struct 'Container'
//        has non-Sendable type 'ThreadConfinedState'
//
// struct Container: Sendable {
//     let state: ThreadConfinedState
// }

// ============================================================================
// MARK: - V8: Pattern match for IOUring.Ring
//
// Hypothesis: A class matching Ring's actual shape (stored properties:
//   Kernel.Descriptor equivalent, mmap regions, cached pointers) compiles
//   as ~Sendable.
// Result: (pending)
// ============================================================================

final class FakeRing: ~Sendable {
    let fd: Int32
    var sqRingRegion: UnsafeMutableRawPointer?
    var cqRingRegion: UnsafeMutableRawPointer?
    var cachedHead: UInt32 = 0
    var cachedTail: UInt32 = 0

    init(fd: Int32) {
        self.fd = fd
        self.sqRingRegion = nil
        self.cqRingRegion = nil
    }

    deinit {
        print("V8: FakeRing deinit fd=\(fd)")
    }
}

func testV8() {
    let ring = FakeRing(fd: 42)
    ring.cachedHead = 10
    ring.cachedTail = 20
    print("V8: fd=\(ring.fd), head=\(ring.cachedHead), tail=\(ring.cachedTail)")
}

// ============================================================================
// MARK: - Entry Point
// ============================================================================

print("=== V1: Basic ~Sendable class ===")
let s = ThreadConfinedState()
s.increment()
print("V1: counter=\(s.counter)")

print("\n=== V2: Init and mutation ===")
testV2()

print("\n=== V3: Task capture (commented — expected error) ===")
print("  (uncomment to verify rejection)")

print("\n=== V4: Actor argument (commented — expected error) ===")
print("  (uncomment to verify rejection)")

print("\n=== V5: Unmanaged pointer recovery ===")
testV5()

print("\n=== V6: Struct ~Sendable ===")
testV6()

print("\n=== V7: Sendable container (commented — expected error) ===")
print("  (uncomment to verify rejection)")

print("\n=== V8: IOUring.Ring shape ===")
testV8()
