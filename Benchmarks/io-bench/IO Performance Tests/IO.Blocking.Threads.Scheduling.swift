//
//  Scheduling.swift
//  swift-io / Benchmarks / io-bench
//
//  Measures executor thread scheduling latency.
//  Swift-io specific — tests executor thread hop and round-robin.
//

import IO
import Executors
import IO_Test_Support
import Testing

extension Benchmark {

    @Suite struct Scheduling {

        static let executors = Kernel.Thread.Executor.Sharded(.init(count: 4))

        @Test(.timed(iterations: 10, warmup: 3))
        func `task on executor thread`() async {
            let executor = Self.executors.next()
            let result = await Task(executorPreference: executor) { 42 }.value
            withExtendedLifetime(result) {}
        }

        @Test(.timed(iterations: 10, warmup: 3))
        func `round-robin executor distribution`() async {
            let executor = Self.executors.next()
            let result = await Task(executorPreference: executor) { 42 }.value
            withExtendedLifetime(result) {}
        }

        @Test(.timed(iterations: 10, warmup: 3))
        func `default executor baseline`() async {
            let result = await Task { 42 }.value
            withExtendedLifetime(result) {}
        }
    }
}
