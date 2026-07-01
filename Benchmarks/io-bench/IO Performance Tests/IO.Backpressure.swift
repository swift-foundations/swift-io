//
//  Backpressure.swift
//  swift-io / Benchmarks / io-bench
//
//  Capability benchmarks measuring backpressure behavior.
//  Swift-io specific — NIO has no built-in backpressure.
//

import IO
import IO_Blocking
import IO_Blocking_Threads
import IO_Test_Support
import Testing

extension Benchmark {

    @Suite struct Backpressure {}
}

// MARK: - Performance

extension Benchmark.Backpressure {

    static let suspendLane: IO.Blocking.Lane = {
        IO.Blocking.Lane.threads(IO.Blocking.Threads.Options(
            workers: 2, queueLimit: 16, backpressure: .wait
        ))
    }()

    static let sustainedLane: IO.Blocking.Lane = {
        IO.Blocking.Lane.threads(IO.Blocking.Threads.Options(
            workers: 4, queueLimit: 1000, acceptanceWaitersLimit: 1000, backpressure: .wait
        ))
    }()

    static let overloadLane: IO.Blocking.Lane = {
        IO.Blocking.Lane.threads(IO.Blocking.Threads.Options(
            workers: 4, queueLimit: 64, acceptanceWaitersLimit: 128, backpressure: .failFast
        ))
    }()

    @Test(.timed(iterations: 10, warmup: 3))
    func `suspend until capacity with 32 ops`() async throws {
        try await Self.suspendLane.run.concurrent(count: 32) {
            WorkSimulator.simulateWork(duration: .microseconds(100))
        }
    }

    @Test(.timed(iterations: 10, warmup: 3))
    func `sustained load within capacity 1000 ops`() async throws {
        try await Self.sustainedLane.run.concurrent(count: 1000) {
            WorkSimulator.simulateWork(duration: .microseconds(50))
        }
    }

    @Test(.timed(iterations: 5, warmup: 1))
    func `bounded rejection under overload`() async throws {
        var rejected = 0
        await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<1000 {
                group.addTask {
                    do {
                        try await Self.overloadLane.run {
                            WorkSimulator.simulateWork(duration: .microseconds(100))
                        }
                        return true
                    } catch { return false }
                }
            }
            for await success in group {
                if !success { rejected += 1 }
            }
        }
        #expect(rejected > 0, "Expected some ops to be rejected under overload")
    }

    @Test(.timed(iterations: 10, warmup: 3))
    func `pure rejection latency on saturated lane`() async throws {
        let lane = await SaturatedLaneFixture.get().lane
        var rejections = 0
        for _ in 0..<1000 {
            do {
                let _: Int = try await lane.run(
                    deadline: Clock.Suspending.Instant.after(.milliseconds(1))
                ) { 42 }
            } catch {
                switch error {
                case .failure(.left(.queue(.full))), .timeout:
                    rejections += 1
                default: break
                }
            }
        }
        #expect(rejections == 1000, "All should reject on saturated lane")
    }
}
