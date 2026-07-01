// Toolchain: Swift 6.3.1 (2026-04-30) — anchor added during Phase 7a sweep [EXP-007a]
// Revalidated: Swift 6.3.1 (2026-04-30) — PASSES
//
// Experiment 2: Can a ~Copyable be passed `borrowing` across actor
// boundary via an isolated async method?
//
// Kernel.Descriptor is ~Copyable. The current IO.Context._read takes
// `borrowing Kernel.Descriptor` in a SYNC closure. If Runner becomes
// an actor with async isolated methods, the question is:
//
//     func read(from: borrowing Descriptor, ...) async -> Int
//
// Swift has historically rejected `borrowing` across `await` because
// the borrow spans a suspension. SE-0432 (Borrowing Noncopyable Types)
// does allow borrow-across-await under specific rules. Test which.

// ============================================================================
// Minimal ~Copyable "descriptor"
// ============================================================================

struct Descriptor: ~Copyable {
    let rawValue: Int32
    init(_ raw: Int32) { self.rawValue = raw }
}

// ============================================================================
// Actor with borrowing async methods
// ============================================================================

actor Runner {
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        // Default cooperative.
        MainActor.sharedUnownedExecutor
    }

    // Test 1: borrowing ~Copyable, async
    func read(from descriptor: borrowing Descriptor) async -> Int32 {
        return descriptor.rawValue
    }

    // Test 2: consuming ~Copyable, async
    func close(_ descriptor: consuming Descriptor) async {
        _ = descriptor.rawValue
    }

    // Test 3: inout sending, async
    func inoutReborrow(_ descriptor: inout sending Descriptor) async {
        _ = descriptor.rawValue
    }
}

@main
struct Main {
    static func main() async {
        let runner = Runner()

        // === Test 1: call `runner.read(from: descriptor)` with borrow ===
        let d1 = Descriptor(3)
        #if PROBE_BORROW_ASYNC
        let n = await runner.read(from: d1)
        print("borrow async:", n, "still have d1:", d1.rawValue)
        #endif

        _ = d1.rawValue

        // === Test 2: consuming ~Copyable into actor ===
        #if PROBE_CONSUME_ASYNC
        let d2 = Descriptor(4)
        await runner.close(d2)
        // Cannot use d2 here — consumed.
        #endif

        // === Test 3: inout sending ===
        #if PROBE_INOUT_SENDING
        var d3 = Descriptor(5)
        await runner.inoutReborrow(&d3)
        print("post-inout:", d3.rawValue)
        #endif
    }
}
