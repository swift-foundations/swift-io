//
//  Allocation.swift
//  swift-io / Benchmarks / io-bench
//
//  Measures memory allocation patterns.
//  Swift-io specific — tests boxing, error transport, allocation pressure.
//

import IO
import IO_Blocking
import IO_Blocking_Threads
import IO_Test_Support
import Testing

extension Benchmark {

    @Suite struct Allocation {

        struct LargeResult: Sendable {
            var data: [UInt8]
            init(size: Int) { self.data = [UInt8](repeating: 0xAB, count: size) }
        }

        struct DetailedError: Swift.Error, Sendable {
            var code: Int
            var message: Swift.String
            var context: [Swift.String: Swift.String]
            static func sample() -> DetailedError {
                DetailedError(
                    code: 42,
                    message: "Something went wrong" as Swift.String,
                    context: ["key1": "value1", "key2": "value2"] as [Swift.String: Swift.String]
                )
            }
        }

        static let fixture = IOBenchmarkFixture.shared
        static let batchSize = 100

        static let pressureLane: IO.Blocking.Lane = {
            IO.Blocking.Lane.threads(.init(workers: 4))
        }()

        @Test(.timed(iterations: 10, warmup: 3))
        func `100 per-operation allocations`() async throws {
            let lane = Self.fixture.lane
            for _ in 0..<Self.batchSize {
                let result: Int = try await lane.run { 42 }
                withExtendedLifetime(result) {}
            }
        }

        @Test(.timed(iterations: 10, warmup: 3))
        func `1KB result boxing overhead`() async throws {
            let result: LargeResult = try await Self.fixture.lane.run {
                LargeResult(size: 1024)
            }
            withExtendedLifetime(result) {}
        }

        @Test(.timed(iterations: 10, warmup: 3))
        func `error boxing overhead`() async throws {
            do {
                let _: Int = try await Self.fixture.lane.run { () throws(DetailedError) -> Int in
                    throw DetailedError.sample()
                }
            } catch {
                // Expected: operation error surfaces as .failure(.right(DetailedError))
                withExtendedLifetime(error) {}
            }
        }

        @Test(.timed(iterations: 5, warmup: 1))
        func `sustained memory pressure 1000 ops`() async throws {
            try await Self.pressureLane.run.concurrent(count: 1000) {
                _ = [UInt8](repeating: 0xCD, count: 256)
            }
        }
    }
}
