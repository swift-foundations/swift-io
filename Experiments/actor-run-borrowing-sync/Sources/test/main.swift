// Toolchain: Swift 6.3.1 (2026-04-30) — anchor added during Phase 7a sweep [EXP-007a]
// Revalidated: Swift 6.3.1 (2026-04-30) — PASSES
//
// Experiment 4: Actor.run + borrowing ~Copyable sync call inside body
//
// Inside `@Sendable (isolated Self) async -> R` body, can we call
// an isolated method with `borrowing Descriptor` SYNCHRONOUSLY
// (without await, since we're already on the actor's executor)?

import Dispatch

struct Descriptor: ~Copyable, Sendable {
    let raw: Int32
    init(_ r: Int32) { self.raw = r }
}

struct IOError: Error, Sendable {
    let code: Int
}

final class ThreadExecutor: SerialExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.one")
    func enqueue(_ job: UnownedJob) {
        queue.async { [self] in
            unsafe job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }
    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        unsafe UnownedSerialExecutor(ordinary: self)
    }
}

actor Runner {
    let executor: ThreadExecutor
    init() { self.executor = ThreadExecutor() }
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    // Isolated method — can be called sync from within isolation.
    func read(from fd: borrowing Descriptor) throws(IOError) -> Int32 {
        return fd.raw
    }

    // Actor.run — Point-Free baseline.
    func run<R, E: Error>(
        _ body: @Sendable (isolated Runner) async throws(E) -> sending R
    ) async throws(E) -> sending R {
        try await body(self)
    }
}

@main
struct Main {
    static func main() async throws {
        let runner = Runner()
        let fd = Descriptor(42)

        // CANNOT borrow fd across the `run` call boundary — fd is captured
        // by @Sendable body. It's value-captured (or is Descriptor ~Copyable
        // means it MUST be consumed/borrowed?).
        //
        // For ~Copyable, capture IS consume — not allowed for @Sendable? Test.

        // Approach 1: consume fd into the body.
        let result: Int32 = try await runner.run { [consumed = consume fd] runner in
            // Inside body, we have `consumed: Descriptor`. Call sync.
            let n = try runner.read(from: consumed)  // SYNC call!
            // Can we use consumed again? It's a local var now, yes.
            let m = try runner.read(from: consumed)
            return n + m
        }
        print("result:", result)
    }
}
