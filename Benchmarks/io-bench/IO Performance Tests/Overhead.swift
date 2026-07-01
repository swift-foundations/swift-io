//
//  Overhead.swift
//  swift-io / Benchmarks / io-bench
//
//  Measures per-operation dispatch overhead with trivial work.
//  Mirror of nio-bench with identical workloads and test names.
//

import IO
import IO_Blocking
import IO_Test_Support
import Testing

extension Benchmark {

    @Suite struct Overhead {

        static let fixture = IOBenchmarkFixture.shared
        static let batchSize = 100

        @Test(.timed(iterations: 10, warmup: 3))
        func `single dispatch round-trip`() async throws {
            let result: Int = try await Self.fixture.lane.run { 42 }
            withExtendedLifetime(result) {}
        }

        @Test(.timed(iterations: 10, warmup: 3))
        func `100 sequential dispatches`() async throws {
            let lane = Self.fixture.lane
            for _ in 0..<Self.batchSize {
                let result: Int = try await lane.run { 42 }
                withExtendedLifetime(result) {}
            }
        }
    }
}
