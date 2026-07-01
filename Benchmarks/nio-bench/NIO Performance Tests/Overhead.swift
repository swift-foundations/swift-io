//
//  Overhead.swift
//  swift-io / Benchmarks / nio-bench
//
//  Measures per-operation dispatch overhead with trivial work.
//  Mirror of io-bench with identical workloads and test names.
//

import NIOCore
import NIOPosix
import Testing

extension Benchmark {

    @Suite struct Overhead {

        static let fixture = NIOFixture.shared

        @Test(.timed(iterations: 10, warmup: 3))
        func `single dispatch round-trip`() async throws {
            let pool = Self.fixture.pool
            let el = Self.fixture.eventLoop
            let result = try await pool.runIfActive(eventLoop: el) { 42 }.get()
            withExtendedLifetime(result) {}
        }

        @Test(.timed(iterations: 10, warmup: 3))
        func `100 sequential dispatches`() async throws {
            let pool = Self.fixture.pool
            let el = Self.fixture.eventLoop
            for _ in 0..<100 {
                let result = try await pool.runIfActive(eventLoop: el) { 42 }.get()
                withExtendedLifetime(result) {}
            }
        }
    }
}
