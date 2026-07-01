//
//  Throughput.swift
//  swift-io / Benchmarks / nio-bench
//
//  Measures operations per second with simulated blocking work.
//  Mirror of io-bench with identical workloads and test names.
//

import NIOCore
import NIOPosix
import Testing

extension Benchmark {

    @Suite struct Throughput {

        static let fixture = NIOFixture.shared

        @Test(.timed(iterations: 10, warmup: 3))
        func `1000 sequential ops with 10µs work`() async throws {
            let pool = Self.fixture.pool
            let el = Self.fixture.eventLoop
            for _ in 0..<1000 {
                _ = try await pool.runIfActive(eventLoop: el) {
                    WorkSimulator.simulateWork(duration: .microseconds(10))
                    return 1
                }.get()
            }
        }

        @Test(.timed(iterations: 10, warmup: 3))
        func `1000 concurrent ops with 10µs work`() async throws {
            let pool = Self.fixture.pool
            let el = Self.fixture.eventLoop
            try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0..<1000 {
                    group.addTask {
                        try await pool.runIfActive(eventLoop: el) {
                            WorkSimulator.simulateWork(duration: .microseconds(10))
                            return 1
                        }.get()
                    }
                }
                for try await _ in group {}
            }
        }

        @Test(.timed(iterations: 10, warmup: 3))
        func `100 concurrent ops with 1ms work`() async throws {
            let pool = Self.fixture.pool
            let el = Self.fixture.eventLoop
            try await withThrowingTaskGroup(of: Int.self) { group in
                for _ in 0..<100 {
                    group.addTask {
                        try await pool.runIfActive(eventLoop: el) {
                            WorkSimulator.simulateWork(duration: .milliseconds(1))
                            return 1
                        }.get()
                    }
                }
                for try await _ in group {}
            }
        }
    }
}
