//
//  Sharding.swift
//  swift-io / Benchmarks / io-bench
//
//  Measures sharded vs single-lane throughput and scheduling policy effects.
//  No NIO equivalent — NIO has no sharding or scheduling configuration.
//

import IO
import IO_Executor
import IO_Blocking_Threads
import IO_Test_Support
import Testing

extension Benchmark {

    @Suite struct Sharding {

        static let ops = 1000
        static let workDuration = Duration.microseconds(10)

        static let sharded4x1: IO.Lane = {
            IO.Lane.sharded(count: 4) { .threads(.init(workers: 1)) }
        }()

        static let single4: IO.Lane = {
            IO.Lane.threads(.init(
                workers: 4,
                queueLimit: 4000,
                backpressure: .wait
            ))
        }()

        static let fifoLane: IO.Lane = {
            IO.Lane.threads(.init(
                workers: 4,
                scheduling: .fifo
            ))
        }()

        static let lifoLane: IO.Lane = {
            IO.Lane.threads(.init(
                workers: 4,
                scheduling: .lifo
            ))
        }()

        @Test(.timed(iterations: 5, warmup: 1))
        func `1000 concurrent ops sharded 4x1 workers`() async throws {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.ops {
                    group.addTask {
                        _ = try await IO.run(on: Self.sharded4x1) {
                            WorkSimulator.simulateWork(duration: Self.workDuration)
                        }
                    }
                }
                try await group.waitForAll()
            }
        }

        @Test(.timed(iterations: 5, warmup: 1))
        func `1000 concurrent ops single 4 workers`() async throws {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<Self.ops {
                    group.addTask {
                        _ = try await IO.run(on: Self.single4) {
                            WorkSimulator.simulateWork(duration: Self.workDuration)
                        }
                    }
                }
                try await group.waitForAll()
            }
        }

        @Test(.timed(iterations: 10, warmup: 3))
        func `1000 sequential ops FIFO scheduling`() async throws {
            for _ in 0..<Self.ops {
                _ = try await IO.run(on: Self.fifoLane) {
                    WorkSimulator.simulateWork(duration: Self.workDuration)
                }
            }
        }

        @Test(.timed(iterations: 10, warmup: 3))
        func `1000 sequential ops LIFO scheduling`() async throws {
            for _ in 0..<Self.ops {
                _ = try await IO.run(on: Self.lifoLane) {
                    WorkSimulator.simulateWork(duration: Self.workDuration)
                }
            }
        }
    }
}
