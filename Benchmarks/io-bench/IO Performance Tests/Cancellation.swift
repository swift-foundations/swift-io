//
//  Cancellation.swift
//  swift-io / Benchmarks / io-bench
//
//  Measures cancellation overhead and semantics.
//  Swift-io specific — tests cancellation before/after acceptance.
//

import IO
import IO_Blocking
import IO_Blocking_Threads
import IO_Test_Support
import Testing

extension Benchmark {

    @Suite struct Cancellation {}
}

// MARK: - Performance

extension Benchmark.Cancellation {

    @Test(.timed(iterations: 10, warmup: 3))
    func `pre-acceptance cancellation latency`() async throws {
        let lane = await BusyLaneFixture.get().lane
        let cancelledTask = Task {
            do {
                return try await lane.run { 42 }
            } catch { return -1 }
        }
        cancelledTask.cancel()
        let result = await cancelledTask.value
        #expect(result == -1)
    }

    @Test(.timed(iterations: 10, warmup: 3))
    func `post-acceptance cancellation`() async throws {
        let lane = IOBenchmarkFixture.shared.lane

        // ReadySignal bridges from the worker thread (which calls arrive())
        // back to the async context, confirming the work has been accepted
        // before we cancel the task.
        let accepted = ReadySignal(target: 1)

        let task = Task {
            do {
                return try await lane.run {
                    accepted.arrive()
                    WorkSimulator.simulateWork(duration: .milliseconds(5))
                    return 42
                }
            } catch { return -1 }
        }

        await accepted.ready()
        // Worker is executing. Cancel the task.
        task.cancel()
        _ = await task.value
    }

    @Test(.timed(iterations: 5, warmup: 1))
    func `batch cancellation of 100 tasks`() async throws {
        let workerCount = 4
        let scope = IO.Blocking.Lane.Scope(.threads(.init(workers: 4)))
        let lane = scope.lane

        // Wait until all workers are busy before cancelling.
        let workersActive = ReadySignal(target: workerCount)

        let parentTask = Task {
            do {
                return try await withThrowingTaskGroup(of: Int.self) { group in
                    for i in 0..<100 {
                        group.addTask {
                            try await lane.run {
                                workersActive.arrive()
                                WorkSimulator.simulateWork(duration: .milliseconds(1))
                                return i
                            }
                        }
                    }
                    var sum = 0
                    for try await value in group { sum += value }
                    return sum
                }
            } catch {
                return -1
            }
        }

        await workersActive.ready()
        parentTask.cancel()
        _ = await parentTask.result
        await scope.close()
    }
}
