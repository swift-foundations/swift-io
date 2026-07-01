//
//  NIOFixture.swift
//  swift-io-benchmarks
//
//  Pre-configured NIOThreadPool for steady-state benchmarks.
//

import NIOCore
import NIOPosix

/// Shared fixture providing a pre-created NIOThreadPool.
///
/// Thread count matches IO fixture (4 threads) for fair comparison.
/// Uses a single EventLoop for result delivery (minimum NIO setup).
final class NIOFixture: @unchecked Sendable {
    let pool: NIOThreadPool
    let eventLoopGroup: MultiThreadedEventLoopGroup
    let eventLoop: any EventLoop
    let threadCount: Int

    static let shared = NIOFixture()

    init(threadCount: Int = 4) {
        self.threadCount = threadCount
        self.pool = NIOThreadPool(numberOfThreads: threadCount)
        self.pool.start()
        self.eventLoopGroup = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.eventLoop = self.eventLoopGroup.next()
    }
}
