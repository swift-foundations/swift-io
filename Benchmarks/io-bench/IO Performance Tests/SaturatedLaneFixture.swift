//
//  SaturatedLaneFixture.swift
//  swift-io / Benchmarks / io-bench
//
//  Pre-saturated lane shared across `.timed()` iterations.
//

import IO
import IO_Blocking
import IO_Blocking_Threads
import IO_Test_Support
import Synchronization
import Testing

/// Pre-saturated lane for rejection latency benchmarks.
///
/// ## Saturation guarantee
///
/// Two-phase setup ensures the lane is fully saturated (workers busy AND
/// queue full) before the fixture is returned:
///
/// **Phase 1 — Occupy workers:** Exactly 2 workers, each confirmed via
/// `ReadySignal.arrive()` from its dedicated OS thread. Workers block on
/// `Kernel.Thread.Condition.wait(mutex:)` — indefinite, zero-CPU.
///
/// **Phase 2 — Fill queue:** After all workers are confirmed blocked,
/// `laneQueueLimit` filler jobs are submitted. These enter the queue but
/// cannot execute (no worker available). The `onStateTransition` callback
/// signals when the queue transitions to `.saturated`. A `SaturationGate`
/// prevents false triggers from Phase 1.
///
/// After both phases, every submission hits `failFast` → `.queue(.full)`.
///
/// ## Sync enqueue setup
///
/// Both phases use the sync `lane.run` overload (`@discardableResult`)
/// which enqueues under a lock and returns a `Handle` — zero cooperative
/// pool involvement. The discarded handle's deinit registers callback-based
/// cleanup that fires when the worker eventually completes (at teardown).
/// This avoids cooperative pool starvation that the prior `withTaskGroup`
/// + `cancelAll()` approach suffered from under concurrent test load.
///
/// ## Teardown
/// Broadcasting the condition releases blocked workers, which then drain
/// the filler jobs from the queue. `lane.shutdown()` waits for all
/// in-flight jobs to complete via the shutdown gate.
enum SaturatedLaneFixture {

    /// Prevents Phase 1 saturation events from triggering the Phase 2
    /// ready signal. Both blocker jobs may be enqueued before workers
    /// start, briefly saturating the queue during Phase 1.
    private final class SaturationGate: @unchecked Sendable {
        private let lock = Kernel.Thread.Mutex()
        private var armed = false

        func arm() {
            lock.lock()
            armed = true
            lock.unlock()
        }

        func isArmed() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return armed
        }
    }

    struct State: Sendable {
        let lane: IO.Blocking.Lane
        fileprivate let mutex: Kernel.Thread.Mutex
        fileprivate let condition: Kernel.Thread.Condition

        func tearDown() async {
            mutex.lock()
            condition.broadcast()
            mutex.unlock()
        }
    }

    private static let _state = Mutex<State?>(nil)

    static func get() async -> State {
        if let s = _state.withLock({ $0 }) { return s }
        let s = await create()
        Test.Teardown.register { await s.tearDown() }
        _state.withLock { $0 = s }
        return s
    }

    private static func create() async -> State {
        let mutex = Kernel.Thread.Mutex()
        let condition = Kernel.Thread.Condition()
        let workerCount = 2
        let queueLimit = 2

        let gate = SaturationGate()
        let saturatedSignal = ReadySignal(target: 1)

        let lane = IO.Blocking.Lane.threads(IO.Blocking.Threads.Options(
            workers: .init(integerLiteral: UInt(workerCount)),
            policy: IO.Backpressure.Policy(
                strategy: .failFast,
                laneQueueLimit: queueLimit
            ),
            onStateTransition: { transition in
                if transition == .became(.saturated), gate.isArmed() {
                    saturatedSignal.arrive()
                }
            }
        ))

        // Phase 1: Occupy all workers with indefinitely-blocking closures.
        // Sync enqueue — no cooperative pool threads consumed.
        let workerSignal = ReadySignal(target: workerCount)

        for _ in 0..<workerCount {
            do {
                try lane.run.sync {
                    workerSignal.arrive()
                    mutex.lock()
                    condition.wait(mutex: mutex)
                    mutex.unlock()
                }
            } catch {
                preconditionFailure(
                    "SaturatedLaneFixture: worker setup failed: \(error)"
                )
            }
        }
        await workerSignal.ready()
        // All workers confirmed execution. Queue is empty.

        // Phase 2: Fill the queue. Workers are blocked on the condition,
        // so these jobs sit in the queue until teardown releases them.
        // Sync enqueue — the saturation callback fires synchronously
        // on this thread during the second enqueue.
        gate.arm()

        for _ in 0..<queueLimit {
            do {
                try lane.run.sync {}
            } catch {
                preconditionFailure(
                    "SaturatedLaneFixture: queue fill failed: \(error)"
                )
            }
        }
        await saturatedSignal.ready()
        // Queue is full. All subsequent submissions hit failFast.

        return State(
            lane: lane,
            mutex: mutex,
            condition: condition
        )
    }
}
