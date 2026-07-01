// Toolchain: Swift 6.3.1 (2026-04-30) — anchor added during Phase 7a sweep [EXP-007a]
// Revalidated: Swift 6.3.1 (2026-04-30) — PASSES
//
// Experiment 1: Q2 — Can we avoid @Sendable on Actor.run body?
//
// Parent session found: sending on body fails with "region-based isolation
// checker does not understand how to check. Please file a bug."
// Reproduce here, then probe every adjacent variant.

import Synchronization

// ============================================================================
// MARK: - Minimal custom executor (no OS thread — just synchronous fallback)
// ============================================================================

final class InlineSerialExecutor: SerialExecutor, @unchecked Sendable {
    func enqueue(_ job: UnownedJob) {
        // Inline — we only care about compile-time semantics in this file.
        unsafe job.runSynchronously(on: asUnownedSerialExecutor())
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        unsafe UnownedSerialExecutor(ordinary: self)
    }
}

// ============================================================================
// MARK: - Actor declarations — four variants of the `run` signature
// ============================================================================

actor RunnerSendable {
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        InlineSerialExecutor().asUnownedSerialExecutor()
    }

    // Variant 1: @Sendable body (Point-Free baseline). Compiles ✓
    func run<R, E: Error>(
        _ body: @Sendable (isolated RunnerSendable) async throws(E) -> sending R
    ) async throws(E) -> sending R {
        try await body(self)
    }
}

actor RunnerSending {
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        InlineSerialExecutor().asUnownedSerialExecutor()
    }

    // Variant 2: `sending` body with `isolated Self` param (parent's pattern)
    // — expect compiler error.
    func run<R, E: Error>(
        _ body: sending (isolated RunnerSending) async throws(E) -> sending R
    ) async throws(E) -> sending R {
        try await body(self)
    }

    // Variant 2b: `sending` body WITHOUT isolated Self param.
    // Relies on SE-0461: async closures inherit caller's isolation.
    // The closure type `() async -> R` is not already isolated, so sending
    // may be allowed. Inside `run` (isolated to self), awaiting body()
    // inherits self's isolation — body runs on self's executor.
    func runNoIsolatedParam<R, E: Error>(
        _ body: sending () async throws(E) -> sending R
    ) async throws(E) -> sending R {
        try await body()
    }

    // Internal isolated operation — the body should call this and stay
    // on the runner's executor. Test with SE-0461.
    func doWork(_ x: Int) -> Int { x * 2 }

    // Variant 2c: `sending` body + `@_inheritActorContext`-style. Let's see
    // if the compiler figures out body runs on our executor.
    func runAsync<R, E: Error>(
        _ body: sending @isolated(any) () async throws(E) -> sending R
    ) async throws(E) -> sending R {
        try await body()
    }
}

actor RunnerPlain {
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        InlineSerialExecutor().asUnownedSerialExecutor()
    }

    // Variant 3: plain closure (no annotation). Expect failure at call site.
    func run<R, E: Error>(
        _ body: (isolated RunnerPlain) async throws(E) -> sending R
    ) async throws(E) -> sending R {
        try await body(self)
    }
}

// Variant 4: nonisolated method, manual isolated(to:) hop. Parent didn't test.
actor RunnerIsolatedParam {
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        InlineSerialExecutor().asUnownedSerialExecutor()
    }

    // Isolated method. Whatever closure annotation, does `await p.perform { }`
    // from outside compile when the closure captures non-Sendable state?
    func perform<R>(_ body: () -> R) -> R {
        body()
    }

    func performSendable<R>(_ body: @Sendable () -> R) -> R {
        body()
    }

    func performSending<R>(_ body: sending () -> R) -> R {
        body()
    }
}

// ============================================================================
// MARK: - Probe: capture non-Sendable state
// ============================================================================

final class NonSendable {
    var value: Int = 0
    init(_ v: Int) { self.value = v }
}

@main
struct Main {
    static func main() async throws {
        let s = RunnerSendable()
        let sending = RunnerSending()
        let p = RunnerIsolatedParam()

        // --- Baseline: @Sendable body at call site ---
        #if PROBE_SENDABLE_RUN
        let box = NonSendable(42)
        let _: Int = try await s.run { (runner: isolated RunnerSendable) in
            box.value += 1   // ERROR expected: NonSendable not Sendable
            return box.value
        }
        #endif

        // --- SE-0430 `sending` body at call site ---
        // Parent reported this fails — reproduce.
        #if PROBE_SENDING_RUN
        let _: Int = try await sending.run { (runner: isolated RunnerSending) in
            return 42
        }
        #endif

        // Variant 2b: sending body WITHOUT isolated Self
        // (no post-access to captured state — the closure is one-shot)
        #if PROBE_SENDING_NO_ISOLATED
        let _: Int = try await sending.runNoIsolatedParam {
            // consumable work; captures only Sendable state
            return 42
        }
        #endif

        // Variant 2b with non-Sendable capture consumed-only inside.
        #if PROBE_SENDING_NO_ISOLATED_CAPTURE
        let localBox = NonSendable(42)  // created fresh, used once
        let _: Int = try await sending.runNoIsolatedParam {
            localBox.value += 1
            return localBox.value
        }
        // Cannot access localBox afterwards — compiler must accept this.
        #endif

        // Variant 2b: inside body, call an actor-isolated method on sending.
        // Does `sending.doWork(x)` need an await? Is it free?
        #if PROBE_SENDING_INSIDE_CALL
        // The body doesn't carry `isolated RunnerSending`, so calls to
        // sending.doWork must go through the normal async hop.
        let _: Int = try await sending.runNoIsolatedParam { [sending] in
            let y = await sending.doWork(41)
            return y
        }
        #endif

        // Variant 2c: @isolated(any) body
        #if PROBE_ISOLATED_ANY
        let _: Int = try await sending.runAsync {
            return 42
        }
        #endif

        _ = sending

        let box2 = NonSendable(42)

        // Probe each `perform` variant. Which (if any) compiles?
        #if PROBE_PLAIN
        let r = await p.perform {
            box2.value += 1
            return box2.value
        }
        print("plain:", r)
        #endif

        #if PROBE_SENDABLE
        let r = await p.performSendable {
            box2.value += 1
            return box2.value
        }
        print("sendable:", r)
        #endif

        #if PROBE_SENDING
        let r = await p.performSending {
            box2.value += 1
            return box2.value
        }
        print("sending:", r)
        box2.value += 100
        print("box2 after sending:", box2.value)
        #endif

        _ = s
    }
}
