//
//  Selector.swift
//  swift-io / Benchmarks / io-bench
//
//  Measures kqueue selector performance: registration, arm latency, wakeup.
//  Mirror of nio-bench with identical workloads and test names.
//

import IO
import Kernel
import Testing

extension Benchmark {

    @Suite struct Selector {

        static func makeNonBlockingPipe() throws -> Kernel.Pipe.Descriptors {
            let pipe = try Kernel.Pipe.pipe()
            try Kernel.File.Control.setNonBlocking(pipe.read)
            try Kernel.File.Control.setNonBlocking(pipe.write)
            return pipe
        }
    }
}

// MARK: - Performance

extension Benchmark.Selector {

    // FIXME: selector.register() is package — benchmarks need Channel-based equivalents.

    @Test(.timed(iterations: 10, warmup: 3))
    func `register deregister cycle on pipe`() async throws {
    }

    @Test(.timed(iterations: 10, warmup: 3))
    func `arm read readiness on pipe`() async throws {
    }

    @Test(.timed(iterations: 10, warmup: 3))
    func `arm read write round-trip on pipe`() async throws {
    }
}
