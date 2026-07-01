// Toolchain: Swift 6.3.1 (2026-04-30) — anchor added during Phase 7a sweep [EXP-007a]
// Revalidated: Swift 6.3.1 (2026-04-30) — PASSES
//
// Probe: does an actor with `let executor: any SerialExecutor` storage
// + nonisolated `unownedExecutor` returning `executor.asUnownedSerialExecutor()`
// compile and behave correctly?
//
// If broken: fall back to per-strategy concrete actor type (TCA26 pattern of
// any Actor forwarding).

import Dispatch

// Concrete strategy A — backed by a DispatchQueue serial executor
final class QueueExecutor: SerialExecutor, @unchecked Sendable {
    let queue: DispatchQueue
    init(label: String) { self.queue = DispatchQueue(label: label) }
    func enqueue(_ job: UnownedJob) {
        queue.async { [self] in
            unsafe job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }
    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        unsafe UnownedSerialExecutor(ordinary: self)
    }
}

// Concrete strategy B — different executor type
final class OtherQueueExecutor: SerialExecutor, @unchecked Sendable {
    let queue: DispatchQueue
    init(label: String) { self.queue = DispatchQueue(label: label) }
    func enqueue(_ job: UnownedJob) {
        queue.async { [self] in
            unsafe job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }
    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        unsafe UnownedSerialExecutor(ordinary: self)
    }
}

// The load-bearing question: actor with `any SerialExecutor` storage.
public actor IO {
    let executor: any SerialExecutor

    init(executor: any SerialExecutor) {
        self.executor = executor
    }

    nonisolated public var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    func ping() -> String { "pong from \(type(of: executor))" }
}

// PF-style block API: take an `isolated IO` parameter from a body closure.
public func runIO<R: Sendable>(
    on executor: any SerialExecutor,
    body: @Sendable (isolated IO) async throws -> R
) async rethrows -> R {
    let actor = IO(executor: executor)
    return try await body(actor)
}

@main
struct Main {
    static func main() async throws {
        // Strategy A
        let execA = QueueExecutor(label: "test.A")
        try await runIO(on: execA) { iso in
            let s = iso.ping()
            print("A: \(s)")
        }

        // Strategy B — different concrete executor type, same IO.Actor public face
        let execB = OtherQueueExecutor(label: "test.B")
        try await runIO(on: execB) { iso in
            let s = iso.ping()
            print("B: \(s)")
        }

        print("OK — any SerialExecutor on actor + isolated parameter works")
    }
}
