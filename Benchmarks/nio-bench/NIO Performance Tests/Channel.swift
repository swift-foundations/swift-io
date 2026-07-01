//
//  Channel.swift
//  swift-io / Benchmarks / nio-bench
//
//  Measures NIO channel I/O throughput over TCP loopback.
//  Mirror of io-bench with identical workloads and test names.
//

import NIOCore
import NIOPosix
import Testing

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension Benchmark {

    @Suite struct Channel {

        static let fixture = Fixture.shared
        static let messageSize = 64
        static let roundTrips = 1000
        static let bulkSize = 1024 * 1024  // 1 MB

        @Test(.timed(iterations: 5, warmup: 1))
        func `echo 1000 round-trips 64B messages`() async throws {
            let group = Self.fixture.group
            let totalEchoBytes = Self.messageSize * Self.roundTrips

            let echoCollector = ByteCountHandler(targetBytes: totalEchoBytes)

            // Start echo server
            let server = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(EchoHandler())
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()

            let serverPort = server.localAddress!.port!

            // Connect client with handler to collect echoed data
            let client = try await ClientBootstrap(group: group)
                .channelInitializer { channel in
                    channel.pipeline.addHandler(echoCollector)
                }
                .connect(host: "127.0.0.1", port: serverPort)
                .get()

            let message = ByteBuffer(repeating: 0xAB, count: Self.messageSize)

            // Write all messages (pipelined)
            for _ in 0..<Self.roundTrips {
                try await client.writeAndFlush(message)
            }

            // Wait for all echoed data to arrive
            try await echoCollector.waitForBytes()

            try await client.close()
            try await server.close()
        }

        @Test(.timed(iterations: 5, warmup: 1))
        func `read throughput 1MB`() async throws {
            let group = Self.fixture.group
            let chunkSize = 16384

            let byteCounter = ByteCountHandler(targetBytes: Self.bulkSize)

            // Server: receives data
            let server = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(byteCounter)
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()

            let serverPort = server.localAddress!.port!

            // Client: sends 1MB
            let client = try await ClientBootstrap(group: group)
                .connect(host: "127.0.0.1", port: serverPort)
                .get()

            var remaining = Self.bulkSize
            while remaining > 0 {
                let toWrite = min(remaining, chunkSize)
                let buf = ByteBuffer(repeating: 0xFF, count: toWrite)
                try await client.writeAndFlush(buf)
                remaining -= toWrite
            }

            try await byteCounter.waitForBytes()

            try await client.close()
            try await server.close()
        }

        @Test(.timed(iterations: 5, warmup: 1))
        func `write throughput 1MB`() async throws {
            let group = Self.fixture.group
            let chunkSize = 16384

            let drainHandler = ByteDrainHandler(target: Self.bulkSize)

            // Server: drains received data
            let server = try await ServerBootstrap(group: group)
                .childChannelInitializer { channel in
                    channel.pipeline.addHandler(drainHandler)
                }
                .bind(host: "127.0.0.1", port: 0)
                .get()

            let serverPort = server.localAddress!.port!

            // Client: writes 1MB
            let client = try await ClientBootstrap(group: group)
                .connect(host: "127.0.0.1", port: serverPort)
                .get()

            var remaining = Self.bulkSize
            while remaining > 0 {
                let toWrite = min(remaining, chunkSize)
                let buf = ByteBuffer(repeating: 0xFF, count: toWrite)
                try await client.writeAndFlush(buf)
                remaining -= toWrite
            }

            try await drainHandler.waitUntilDrained()

            try await client.close()
            try await server.close()
        }
    }
}

// MARK: - Handlers

extension Benchmark.Channel {

    /// Echoes back all received data.
    final class EchoHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer
        typealias InboundOut = ByteBuffer

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            context.writeAndFlush(data, promise: nil)
        }
    }

    /// Collects received bytes and signals when target count reached.
    final class ByteCountHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer

        private let targetBytes: Int
        private var receivedBytes: Int = 0
        private var continuation: CheckedContinuation<Void, any Error>?

        init(targetBytes: Int) {
            self.targetBytes = targetBytes
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = unwrapInboundIn(data)
            receivedBytes += buffer.readableBytes
            if receivedBytes >= targetBytes, let cont = continuation {
                continuation = nil
                cont.resume()
            }
        }

        func waitForBytes() async throws {
            if receivedBytes >= targetBytes { return }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                if receivedBytes >= targetBytes {
                    cont.resume()
                } else {
                    self.continuation = cont
                }
            }
        }
    }

    /// Counts bytes written and signals when target count reached.
    final class ByteDrainHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer

        private var totalRead: Int = 0
        private let target: Int
        private var continuation: CheckedContinuation<Void, any Error>?

        init(target: Int) {
            self.target = target
        }

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = unwrapInboundIn(data)
            totalRead += buffer.readableBytes
            if totalRead >= target, let cont = continuation {
                continuation = nil
                cont.resume()
            }
        }

        func waitUntilDrained() async throws {
            if totalRead >= target { return }
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, any Error>) in
                if totalRead >= target {
                    cont.resume()
                } else {
                    self.continuation = cont
                }
            }
        }
    }
}

// MARK: - Fixture

extension Benchmark.Channel {

    final class Fixture: @unchecked Sendable {
        let group: MultiThreadedEventLoopGroup

        static let shared = Fixture()

        init() {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        }
    }
}
