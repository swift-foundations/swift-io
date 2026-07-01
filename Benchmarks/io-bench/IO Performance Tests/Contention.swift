//
//  Contention.swift
//  swift-io / Benchmarks / io-bench
//
//  Measures behavior under thread contention (tasks > threads).
//  Mirror of nio-bench with identical workloads and test names.
//
//  Uses shared high-capacity fixture matching NIO's unbounded queuing.
//

import IO
import IO_Blocking
import IO_Test_Support
import Testing

extension Benchmark {

    @Suite struct Contention {

        static let fixture = IOBenchmarkFixture.highCapacity

        @Test(.timed(iterations: 10, warmup: 3))
        func `moderate contention 40 tasks 4 threads`() async throws {
            try await Self.fixture.lane.run.concurrent(count: 40) {
                WorkSimulator.simulateWork(duration: .microseconds(100))
            }
        }

        @Test(.timed(iterations: 10, warmup: 3))
        func `high contention 400 tasks 4 threads`() async throws {
            try await Self.fixture.lane.run.concurrent(count: 400) {
                WorkSimulator.simulateWork(duration: .microseconds(50))
            }
        }

        @Test(.timed(iterations: 10, warmup: 3))
        func `extreme contention 2000 tasks 4 threads`() async throws {
            try await Self.fixture.lane.run.concurrent(count: 2000) {
                WorkSimulator.simulateWork(duration: .microseconds(10))
            }
        }
    }
}
