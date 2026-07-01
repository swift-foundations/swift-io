//
//  BusyLaneFixture.swift
//  swift-io / Benchmarks / io-bench
//
//  Lane with all workers occupied, shared across `.timed()` iterations.
//

import IO
import IO_Blocking
import IO_Blocking_Threads
import IO_Test_Support
import Synchronization
import Testing

/// Lane with all workers busy for cancellation benchmarks.
///
/// ## Occupancy guarantee
///
/// Exactly 2 workers, `queueLimit: 8`, `wait` strategy. Each worker calls
/// `ReadySignal.arrive()` from its dedicated OS thread. The async context
/// awaits `signal.ready()` which resumes once both workers have confirmed
/// execution. After that, every worker slot is occupied — new submissions
/// suspend in the acceptance waiter path, enabling measurement of
/// pre-acceptance cancellation.
///
/// Workers block on `Kernel.Thread.Condition.wait(mutex:)` — indefinite,
/// zero-CPU. Teardown broadcasts the condition to release all workers.
///
/// ## Sync enqueue setup
///
/// Setup uses the sync `lane.run` overload (`@discardableResult`) which
/// enqueues under a lock and returns a `Handle` — zero cooperative pool
/// involvement. The discarded handle's deinit registers callback-based
/// cleanup that fires when the worker eventually completes (at teardown).
/// This avoids cooperative pool starvation that the prior `withTaskGroup`
/// + `cancelAll()` approach suffered from under concurrent test load.
enum BusyLaneFixture {

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

        let lane = IO.Blocking.Lane.threads(IO.Blocking.Threads.Options(
            workers: 2,
            policy: IO.Backpressure.Policy(
                strategy: .wait,
                laneQueueLimit: 8
            )
        ))

        // Sync enqueue — no cooperative pool threads consumed.
        let signal = ReadySignal(target: workerCount)

        for _ in 0..<workerCount {
            do {
                try lane.run.sync {
                    signal.arrive()
                    mutex.lock()
                    condition.wait(mutex: mutex)
                    mutex.unlock()
                }
            } catch {
                preconditionFailure(
                    "BusyLaneFixture: worker setup failed: \(error)"
                )
            }
        }
        await signal.ready()

        return State(
            lane: lane,
            mutex: mutex,
            condition: condition
        )
    }
}
