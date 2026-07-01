//
//  HighLevelAPI.swift
//  swift-io / Benchmarks / io-bench
//
//  Measures abstraction cost of IO.run and IO.open vs raw lane dispatch.
//  No NIO equivalent — NIO has no scoped resource API.
//

import IO
import IO_Executor
import IO_Blocking_Threads
import IO_Test_Support
import Testing

extension Benchmark {

    @Suite struct HighLevelAPI {

        static let fixture = IOBenchmarkFixture.shared
        static let batchSize = 100

        static let customLane: IO.Lane = {
            IO.Lane.threads(.init(workers: 4))
        }()

        @Test(.timed(iterations: 10, warmup: 3))
        func `100 ops via IO.run`() async throws {
            for _ in 0..<Self.batchSize {
                let result = try await IO.run { 42 }
                withExtendedLifetime(result) {}
            }
        }

        @Test(.timed(iterations: 10, warmup: 3))
        func `100 ops via raw lane.run`() async throws {
            let lane = Self.fixture.lane
            for _ in 0..<Self.batchSize {
                let result: Int = try await lane.run { 42 }
                withExtendedLifetime(result) {}
            }
        }

        @Test(.timed(iterations: 10, warmup: 3))
        func `100 IO.run on custom lane`() async throws {
            for _ in 0..<Self.batchSize {
                let result = try await IO.run(on: Self.customLane) { 42 }
                withExtendedLifetime(result) {}
            }
        }
    }
}
