// Toolchain: Swift 6.3.1 (2026-04-30) — anchor added during Phase 7a sweep [EXP-007a]
// Revalidated: Swift 6.3.1 (2026-04-30) — PASSES
//
// Verify: can a second actor (MyServer) expose its unownedExecutor as
// `io.executor.asUnownedSerialExecutor()` where `io` is an IO actor
// held as a property?
//
// Subtle: io.executor must be accessible from nonisolated context.
// In Swift 6, `let` properties of Sendable types on actors are
// implicitly accessible nonisolated.

import Dispatch

// Simulated thread executor (Sendable class).
public final class ThreadExecutor: SerialExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "shared")
    public init() {}
    public func enqueue(_ job: UnownedJob) {
        queue.async { [self] in
            unsafe job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }
    public func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        unsafe UnownedSerialExecutor(ordinary: self)
    }
}

// The IO actor. `executor` is let + Sendable → implicitly nonisolated-accessible.
public actor IO {
    public let executor: ThreadExecutor

    public init(executor: ThreadExecutor) { self.executor = executor }

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    // Isolated method for the test
    public func threadID() -> String { currentThreadAddress() }
}

import Foundation

// App actor that SHARES IO's executor. `io` is let + Sendable.
actor MyServer {
    let io: IO

    init(sharedExecutor: ThreadExecutor) {
        self.io = IO(executor: sharedExecutor)
    }

    // Does this compile? `io.executor` accessed from nonisolated context.
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        io.executor.asUnownedSerialExecutor()
    }

    // Isolated method — runs on shared executor.
    func callIO() async -> (String, String) {
        let mine = unsafe currentThreadAddress()
        let theirs = await io.threadID()
        return (mine, theirs)
    }
}

@inline(never)
func currentThreadAddress() -> String {
    unsafe "\(pthread_self())"
}

@main
struct Main {
    static func main() async {
        let executor = ThreadExecutor()
        let server = MyServer(sharedExecutor: executor)
        let (mine, theirs) = await server.callIO()
        print("MyServer thread:  \(mine)")
        print("IO thread:        \(theirs)")
        print("Same?             \(mine == theirs)")
    }
}
