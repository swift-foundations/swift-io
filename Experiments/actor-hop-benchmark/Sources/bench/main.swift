// Actor hop performance benchmark for Option F
//
// Four scenarios, 10M calls each:
//
//   (1) CROSS_HOP       — caller on cooperative pool, IO on dedicated thread.
//                         Each `await io.noop()` enqueues a job on IO's executor.
//                         This is the worst case — what Option F costs per I/O op
//                         when the consumer does NOT share the executor.
//
//   (2) SHARED_EXECUTOR — caller is an actor whose executor IS IO's executor.
//                         The runtime's executor-match check on await elides
//                         the hop. This is the zero-cost path.
//
//   (3) TASK_PREFERENCE — today's Option A — Task(executorPreference:) +
//                         withTaskExecutorPreference, direct sync closure call.
//                         Baseline for "what Option A costs".
//
//   (4) SAME_ACTOR      — control: call a noop method on the same isolated actor
//                         from inside another isolated method. No hop at all.
//                         Measures pure method-dispatch cost.
//
// Each scenario runs 10M calls. Report min, median, p99, max nanoseconds per op.
//
// Build: swift build -c release
// Run:   .build/release/bench

import Executors
import Dispatch
import Foundation

// ============================================================================
// MARK: - The IO actor (stripped-down Option F prototype)
// ============================================================================

public actor IO {
    public let executor: Kernel.Thread.Executor
    // Mutable to defeat compiler const-folding
    var counter: Int = 0

    public init(executor: Kernel.Thread.Executor) {
        self.executor = executor
    }

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }

    @inline(never)
    public func noop() -> Int {
        counter &+= 1
        return counter
    }

    @inline(never)
    public func callSelf(_ iterations: Int) -> Int {
        for _ in 0..<iterations {
            counter &+= 1
        }
        return counter
    }
}

// Actor that shares IO's executor (TCA26 pattern).
public actor SharedCaller {
    let io: IO
    var sink: Int = 0
    init(io: IO) { self.io = io }

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        io.unownedExecutor
    }

    @inline(never)
    public func run(_ iterations: Int) async -> Int {
        for _ in 0..<iterations {
            sink &+= await io.noop()
        }
        return sink
    }
}

// Actor with Actor.run fast-path body (v2.0 Option B pattern).
public actor IOv2 {
    public let executor: Kernel.Thread.Executor
    var counter: Int = 0
    public init(executor: Kernel.Thread.Executor) { self.executor = executor }
    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        executor.asUnownedSerialExecutor()
    }
    @inline(never)
    public func noop() -> Int { counter &+= 1; return counter }

    // Point-Free Actor.run pattern.
    public func run<R>(
        _ body: @Sendable (isolated IOv2) async -> sending R
    ) async -> sending R { await body(self) }
}

// ============================================================================
// MARK: - Timing
// ============================================================================

// Collect one-shot latencies over many iterations — the whole loop represents
// one sample; we report per-op averages derived from batch timings rather than
// per-call percentiles (per-call timing dominates overhead at this scale).

@inline(never)
func nowNs() -> UInt64 { DispatchTime.now().uptimeNanoseconds }

@inline(never)
func reportLine(_ scenario: Swift.String, iterations: Int, totalNs: UInt64) {
    let perOp = Double(totalNs) / Double(iterations)
    let total = Double(totalNs) / 1e9
    let paddedScenario = scenario.padding(toLength: 28, withPad: " ", startingAt: 0)
    let perOpStr = Swift.String(format: "%8.1f", perOp)
    let totalStr = Swift.String(format: "%.3f", total)
    print("\(paddedScenario)  \(perOpStr) ns/op   (\(totalStr)s total)")
}

// ============================================================================
// MARK: - Scenarios
// ============================================================================

@inline(never)
func scenarioCrossHop(io: IO, iterations: Int) async -> Int {
    // Caller runs on cooperative pool. Each await io.noop() enqueues on IO's
    // executor, job runs, resumes on cooperative pool.
    var sink = 0
    for _ in 0..<iterations {
        sink &+= await io.noop()
    }
    blackHole(sink)
    return sink
}

@inline(never)
func blackHole<T>(_ x: T) {
    @inline(never) func sink(_ p: UnsafeRawPointer) {}
    unsafe withUnsafePointer(to: x) { sink(UnsafeRawPointer($0)) }
}

@inline(never)
func scenarioSharedExecutor(caller: SharedCaller, iterations: Int) async -> Int {
    // Both caller and IO share one Kernel.Thread.Executor.
    await caller.run(iterations)
}

@inline(never)
func scenarioTaskPreference(executor: Kernel.Thread.Executor, iterations: Int) async -> Int {
    // Option A pattern — push a Task onto the executor, call sync closures inside.
    nonisolated(unsafe) var sink = 0
    let result: Int = await withCheckedContinuation {
        (continuation: CheckedContinuation<Int, Never>) in
        Task<Void, Never>(executorPreference: executor) {
            await withTaskExecutorPreference(executor) {
                for _ in 0..<iterations {
                    sink &+= noopSyncClosure()
                }
                continuation.resume(returning: sink)
            }
        }
    }
    blackHole(result)
    return result
}

// Volatile-ish counter to defeat constant-folding.
nonisolated(unsafe) var closureCounter: Int = 0

@inline(never)
func noopSyncClosure() -> Int {
    closureCounter &+= 1
    return closureCounter
}

@inline(never)
func scenarioSameActor(io: IO, iterations: Int) async -> Int {
    // Single hop into the actor; all iterations happen inside.
    // Measures pure per-method-call cost on the actor's executor.
    await io.callSelf(iterations)
}

@inline(never)
func scenarioActorRun(io: IOv2, iterations: Int) async -> Int {
    // Single hop via Actor.run; isolated calls inside elide further hops.
    nonisolated(unsafe) var captured = 0
    await io.run { isolatedIO in
        for _ in 0..<iterations {
            captured &+= isolatedIO.noop()
        }
    }
    blackHole(captured)
    return captured
}

// ============================================================================
// MARK: - Main
// ============================================================================

@main
struct Main {
    static func main() async {
        let iterations = 500_000
        let warmup = 10_000

        // Construct one executor — shared for scenarios 1, 2, 3, 4.
        let executor = Kernel.Thread.Executor(mode: .serial)
        defer { executor.shutdown() }

        let io = IO(executor: executor)
        let sharedCaller = SharedCaller(io: io)
        let iov2Executor = Kernel.Thread.Executor(mode: .serial)
        defer { iov2Executor.shutdown() }
        let iov2 = IOv2(executor: iov2Executor)

        // Warmup
        print("warmup 1…")
        _ = await scenarioCrossHop(io: io, iterations: warmup)
        print("warmup 2…")
        _ = await scenarioSharedExecutor(caller: sharedCaller, iterations: warmup)

        // Task(executorPreference:) with a `.task`-mode executor for fair comparison
        // — the current IO.blocking() code hands a `.serial` executor to
        // Task(executorPreference:), which is latently buggy. We benchmark both.
        let taskExec = Kernel.Thread.Executor(mode: .task)
        defer { taskExec.shutdown() }
        print("warmup 3…")
        _ = await scenarioTaskPreference(executor: taskExec, iterations: warmup)
        print("warmup 4…")
        _ = await scenarioSameActor(io: io, iterations: warmup)
        print("warmup done")

        // Measurements
        print("=== \(iterations) iterations per scenario ===")

        var t0 = nowNs()
        _ = await scenarioCrossHop(io: io, iterations: iterations)
        var t1 = nowNs()
        reportLine("cross-hop", iterations: iterations, totalNs: t1 &- t0)

        t0 = nowNs()
        _ = await scenarioSharedExecutor(caller: sharedCaller, iterations: iterations)
        t1 = nowNs()
        reportLine("shared-executor", iterations: iterations, totalNs: t1 &- t0)

        t0 = nowNs()
        _ = await scenarioTaskPreference(executor: taskExec, iterations: iterations)
        t1 = nowNs()
        reportLine("task-preference(.task)", iterations: iterations, totalNs: t1 &- t0)

        t0 = nowNs()
        _ = await scenarioTaskPreference(executor: executor, iterations: iterations)
        t1 = nowNs()
        reportLine("task-preference(.serial)", iterations: iterations, totalNs: t1 &- t0)

        t0 = nowNs()
        _ = await scenarioSameActor(io: io, iterations: iterations)
        t1 = nowNs()
        reportLine("same-actor-method", iterations: iterations, totalNs: t1 &- t0)

        // Actor.run fast path — one hop + many sync calls.
        _ = await scenarioActorRun(io: iov2, iterations: warmup)  // warmup
        t0 = nowNs()
        _ = await scenarioActorRun(io: iov2, iterations: iterations)
        t1 = nowNs()
        reportLine("actor.run body", iterations: iterations, totalNs: t1 &- t0)
    }
}
