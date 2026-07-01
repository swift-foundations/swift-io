//
//  Lifecycle.swift
//  swift-io / Benchmarks / io-bench
//
//  Measures pool creation, warmup, and shutdown costs.
//  Mirror of nio-bench with identical workloads and test names.
//

import IO
import IO_Executor
import IO_Blocking
import IO_Blocking_Threads
import IO_Test_Support
import Testing

extension Benchmark {

    @Suite struct Lifecycle {

        static let workers: Kernel.Thread.Count = 4

        @Test(.timed(iterations: 10, warmup: 3))
        func `create warm shutdown`() async throws {
            let scope = IO.Lane.Scope(.init(workers: Self.workers))
            try await scope.lane.run {}
            await scope.close()
        }

        @Test(.timed(iterations: 10, warmup: 3))
        func `create 10 ops shutdown`() async throws {
            let scope = IO.Lane.Scope(.init(workers: Self.workers))
            for _ in 0..<10 {
                try await scope.lane.run {
                    WorkSimulator.simulateWork(duration: .microseconds(100))
                }
            }
            await scope.close()
        }
    }
}
