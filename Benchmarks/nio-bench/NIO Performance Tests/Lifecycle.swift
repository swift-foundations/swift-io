//
//  Lifecycle.swift
//  swift-io / Benchmarks / nio-bench
//
//  Measures pool creation, warmup, and shutdown costs.
//  Mirror of io-bench with identical workloads and test names.
//

import NIOCore
import NIOPosix
import Testing

extension Benchmark {

    @Suite struct Lifecycle {

        @Test(.timed(iterations: 10, warmup: 3))
        func `create warm shutdown`() async throws {
            let pool = NIOThreadPool(numberOfThreads: 4)
            pool.start()
            let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let el = elg.next()
            try await pool.runIfActive(eventLoop: el) {}.get()
            try await pool.shutdownGracefully()
            try await elg.shutdownGracefully()
        }

        @Test(.timed(iterations: 10, warmup: 3))
        func `create 10 ops shutdown`() async throws {
            let pool = NIOThreadPool(numberOfThreads: 4)
            pool.start()
            let elg = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            let el = elg.next()
            for _ in 0..<10 {
                try await pool.runIfActive(eventLoop: el) {
                    WorkSimulator.simulateWork(duration: .microseconds(100))
                }.get()
            }
            try await pool.shutdownGracefully()
            try await elg.shutdownGracefully()
        }
    }
}
