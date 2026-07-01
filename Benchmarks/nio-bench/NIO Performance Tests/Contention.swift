//
//  Contention.swift
//  swift-io / Benchmarks / nio-bench
//
//  Measures behavior under thread contention (tasks > threads).
//  Mirror of io-bench with identical workloads and test names.
//
//  NIO uses unbounded queuing — all tasks are always accepted.
//

import NIOCore
import NIOPosix
import Testing

extension Benchmark {

    @Suite struct Contention {

        static let fixture = NIOFixture.shared

        @Test(.timed(iterations: 10, warmup: 3))
        func `moderate contention 40 tasks 4 threads`() async throws {
            let pool = Self.fixture.pool
            let el = Self.fixture.eventLoop
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<40 {
                    group.addTask {
                        try await pool.runIfActive(eventLoop: el) {
                            WorkSimulator.simulateWork(duration: .microseconds(100))
                        }.get()
                    }
                }
                try await group.waitForAll()
            }
        }

        @Test(.timed(iterations: 10, warmup: 3))
        func `high contention 400 tasks 4 threads`() async throws {
            let pool = Self.fixture.pool
            let el = Self.fixture.eventLoop
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<400 {
                    group.addTask {
                        try await pool.runIfActive(eventLoop: el) {
                            WorkSimulator.simulateWork(duration: .microseconds(50))
                        }.get()
                    }
                }
                try await group.waitForAll()
            }
        }

        @Test(.timed(iterations: 10, warmup: 3))
        func `extreme contention 2000 tasks 4 threads`() async throws {
            let pool = Self.fixture.pool
            let el = Self.fixture.eventLoop
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<2000 {
                    group.addTask {
                        try await pool.runIfActive(eventLoop: el) {
                            WorkSimulator.simulateWork(duration: .microseconds(10))
                        }.get()
                    }
                }
                try await group.waitForAll()
            }
        }
    }
}
