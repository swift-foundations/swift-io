// Toolchain: Swift 6.3.1 (2026-04-30) — anchor added during Phase 7a sweep [EXP-007a]
// Revalidated: Swift 6.3.1 (2026-04-30) — PASSES
//
// Experiment 3: Option B-DirectMethods
//
// Runner is an actor whose isolated methods ARE the I/O operations.
// No body closure. No @Sendable anywhere. Consumer hops per call.
//
// Tests:
//   (a) Does the API compile with realistic parameter types?
//   (b) Does a scope wrapper compile without @Sendable on body?
//   (c) Does nested IO work? (different pool, different actor)
//   (d) Does cancellation propagate to syscalls running on actor executor?

import Synchronization
import Dispatch

// ============================================================================
// Minimal simulated primitives (mirror the shape of Kernel/Memory types)
// ============================================================================

struct Descriptor: ~Copyable {
    let raw: Int32
    init(_ r: Int32) { self.raw = r }
}

struct Buffer: @unchecked Sendable {
    let ptr: UnsafeMutableRawBufferPointer
    init(_ ptr: UnsafeMutableRawBufferPointer) { self.ptr = ptr }
}

struct IOError: Error, Sendable {
    let code: Int
}

// ============================================================================
// Dedicated-thread executor
// ============================================================================

final class ThreadExecutor: SerialExecutor, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.executor.dedicated")

    func enqueue(_ job: UnownedJob) {
        queue.async { [self] in
            unsafe job.runSynchronously(on: self.asUnownedSerialExecutor())
        }
    }

    func asUnownedSerialExecutor() -> UnownedSerialExecutor {
        unsafe UnownedSerialExecutor(ordinary: self)
    }
}

// ============================================================================
// IO actor with direct isolated methods
// ============================================================================

actor IO {
    let executor: ThreadExecutor

    init() { self.executor = ThreadExecutor() }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    // Isolated async methods — each call is an actor hop.
    func read(from descriptor: borrowing Descriptor, into buffer: Buffer) throws(IOError) -> Int {
        // Runs on executor's thread. Simulate sync blocking read.
        return descriptor.raw == -1 ? 0 : 5
    }

    func write(to descriptor: borrowing Descriptor, from buffer: Buffer) throws(IOError) -> Int {
        return 5
    }

    func close(_ descriptor: consuming Descriptor) {
        _ = descriptor.raw
    }

    // Report which thread we're running on (for verification).
    func currentThread() -> String {
        return String(describing: Thread.current)
    }

    // Busy loop on actor's executor — test whether the OUTER task's
    // cancellation flag is visible via Task.isCancelled inside an
    // isolated method.
    func busyLoop() throws(IOError) -> UInt64 {
        let start = DispatchTime.now().uptimeNanoseconds
        var count: UInt64 = 0
        while !Task.isCancelled {
            count &+= 1
            if count % 10_000_000 == 0 {
                let elapsed = DispatchTime.now().uptimeNanoseconds &- start
                if elapsed > 500_000_000 { break }
            }
        }
        return count
    }

    // Same but with Task.checkCancellation() — different semantics.
    // It throws CancellationError instead of a flag check.
    func busyLoopChecked() throws -> UInt64 {
        let start = DispatchTime.now().uptimeNanoseconds
        var count: UInt64 = 0
        while true {
            try Task.checkCancellation()
            count &+= 1
            if count % 10_000_000 == 0 {
                let elapsed = DispatchTime.now().uptimeNanoseconds &- start
                if elapsed > 500_000_000 { break }
            }
        }
        return count
    }
}

import Foundation

// ============================================================================
// Scope wrapper — manages the lifetime of an IO instance
// ============================================================================

extension IO {
    // Static scope — creates IO, runs body with it, cleans up.
    // Body runs in caller's isolation (SE-0461) since scope is nonisolated async.
    // No `sending` on body — it's inherited, not transferred.
    nonisolated(nonsending)
    static func scope<R>(
        _ body: (IO) async throws -> R
    ) async rethrows -> R {
        let io = IO()
        defer {
            // Cleanup for executor would go here.
        }
        return try await body(io)
    }

    // Typed throws variant.
    nonisolated(nonsending)
    static func scopeTyped<R, E: Error>(
        _ body: (IO) async throws(E) -> R
    ) async throws(E) -> R {
        let io = IO()
        return try await body(io)
    }
}

// ============================================================================
// Probe: non-Sendable state captured in scope body — does it compile?
// ============================================================================

final class NonSendableState {
    var counter: Int = 0
    init() {}
}

@main
struct Main {
    static func main() async throws {
        // Each call hops the actor. Descriptor is borrowed across async.
        let io = IO()
        let buf = Buffer(UnsafeMutableRawBufferPointer.allocate(byteCount: 16, alignment: 1))
        defer { unsafe buf.ptr.deallocate() }

        let d = Descriptor(3)
        let n = try await io.read(from: d, into: buf)
        print("read:", n, "d.raw still:", d.raw)

        // Multiple borrow-across-async calls on same fd — does it compile?
        try await IO.scope { runner in
            let fd = Descriptor(10)
            let n1 = try await runner.read(from: fd, into: buf)
            let n2 = try await runner.write(to: fd, from: buf)
            let n3 = try await runner.read(from: fd, into: buf)
            print("scoped fd usage:", n1, n2, n3)
            // Finally consume it
            await runner.close(fd)
        }

        // Scope body WITH non-Sendable capture
        let state = NonSendableState()
        try await IO.scope { io in
            state.counter += 1
            let d2 = Descriptor(4)
            let n2 = try await io.read(from: d2, into: buf)
            state.counter += n2
            print("inside scope, state:", state.counter)
        }
        // Post-access — sending? No — body isn't `sending`. Should work.
        print("post-scope state:", state.counter)

        // Nested scope — different IO instance, different actor
        try await IO.scope { outer in
            let n1 = try await outer.read(from: Descriptor(1), into: buf)
            print("outer:", n1)
            try await IO.scope { inner in
                let n2 = try await inner.read(from: Descriptor(2), into: buf)
                print("inner:", n2)
                // Re-call outer from inside inner's scope
                let n3 = try await outer.read(from: Descriptor(3), into: buf)
                print("outer from inner:", n3)
            }
        }

        // Thread verification — same actor → same thread
        await withTaskGroup(of: Void.self) { group in
            let io = IO()
            for i in 0..<4 {
                group.addTask {
                    let t = await io.currentThread()
                    print("task \(i) (same io): \(t)")
                }
            }
        }

        // Different IOs → different threads?
        let io1 = IO()
        let io2 = IO()
        print("io1 thread:", await io1.currentThread())
        print("io2 thread:", await io2.currentThread())

        // Cancellation test 1: sync loop inside scope body
        // Body runs via SE-0461 on Task's isolation (cooperative).
        let task1 = Task {
            try? await IO.scope { io in
                print("task1 start, cancelled=\(Task.isCancelled)")
                let start = DispatchTime.now().uptimeNanoseconds
                var count: UInt64 = 0
                while !Task.isCancelled {
                    count &+= 1
                    if count % 10_000_000 == 0 {
                        let elapsed = DispatchTime.now().uptimeNanoseconds &- start
                        if elapsed > 500_000_000 { break }  // 500ms safety
                    }
                }
                print("task1 end, cancelled=\(Task.isCancelled), iterations=\(count)")
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        task1.cancel()
        _ = await task1.value

        // Cancellation test 2: sync loop INSIDE actor isolated method
        // This is the critical case for IO — blocking syscalls run on actor executor.
        let task2 = Task {
            try? await IO.scope { io in
                print("task2 start, cancelled=\(Task.isCancelled)")
                let n = try await io.busyLoop()
                print("task2 end, busyLoop returned \(n), outerCancelled=\(Task.isCancelled)")
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        task2.cancel()
        _ = await task2.value

        // Cancellation test 3: checkCancellation() inside actor method
        let task3 = Task {
            do {
                try await IO.scope { io in
                    print("task3 start")
                    let n = try await io.busyLoopChecked()
                    print("task3 end, returned \(n)")
                }
            } catch {
                print("task3 caught: \(error)")
            }
        }
        try await Task.sleep(for: .milliseconds(50))
        task3.cancel()
        _ = await task3.value
        print("cancel test done")
    }
}
