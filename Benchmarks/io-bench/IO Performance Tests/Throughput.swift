//
//  Throughput.swift
//  swift-io / Benchmarks / io-bench
//
//  Measures operations per second with simulated blocking work.
//  Mirror of nio-bench with identical workloads and test names.
//

import IO
import IO_Blocking
import IO_Test_Support
import Testing

extension Benchmark {

    @Suite struct Throughput {

        static let fixture = IOBenchmarkFixture.shared
        static let ops = 1000
        static let heavyOps = 100
        static let workDuration = Duration.microseconds(10)
        static let heavyWorkDuration = Duration.milliseconds(1)

        @Test(.timed(iterations: 10, warmup: 3))
        func `1000 sequential ops with 10µs work`() async throws {
            let lane = Self.fixture.lane
            for _ in 0..<Self.ops {
                let result: Int = try await lane.run {
                    WorkSimulator.simulateWork(duration: Self.workDuration)
                    return 1
                }
                withExtendedLifetime(result) {}
            }
        }

        /// Uses `highCapacity` fixture (queueLimit: 4000) to match NIO's unbounded queue.
        /// With the default fixture (queueLimit: 256), ~74% of 1000 ops overflow into
        /// the acceptance waiter path — an unfair structural disadvantage vs NIO.
        static let concurrentFixture = IOBenchmarkFixture.highCapacity

        @Test(.timed(iterations: 10, warmup: 3))
        func `1000 concurrent ops with 10µs work`() async throws {
            try await Self.concurrentFixture.lane.run.concurrent(count: Self.ops) {
                WorkSimulator.simulateWork(duration: Self.workDuration)
            }
        }

        @Test(.timed(iterations: 10, warmup: 3))
        func `100 concurrent ops with 1ms work`() async throws {
            try await Self.concurrentFixture.lane.run.concurrent(count: Self.heavyOps) {
                WorkSimulator.simulateWork(duration: Self.heavyWorkDuration)
            }
        }
    }
}
