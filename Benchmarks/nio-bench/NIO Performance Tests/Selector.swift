//
//  Selector.swift
//  swift-io / Benchmarks / nio-bench
//
//  Measures NIO event loop performance: channel creation, read readiness, wakeup.
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

    @Suite struct Selector {

        static let fixture = Fixture.shared

        @Test(.timed(iterations: 10, warmup: 3))
        func `register deregister cycle on pipe`() async throws {
            let el = Self.fixture.eventLoop

            for _ in 0..<100 {
                let pipe = try Benchmark.Selector.makeNonBlockingPipe()
                let channel = try await NIOPipeBootstrap(group: el)
                    .takingOwnershipOfDescriptor(input: pipe.read)
                    .get()
                try await channel.close()
                close(pipe.write)
            }
        }

        @Test(.timed(iterations: 10, warmup: 3))
        func `arm read readiness on pipe`() async throws {
            let el = Self.fixture.eventLoop

            for _ in 0..<100 {
                let pipe = try Benchmark.Selector.makeNonBlockingPipe()
                let handler = ReadReadyHandler()

                let channel = try await NIOPipeBootstrap(group: el)
                    .channelInitializer { channel in
                        channel.pipeline.addHandler(handler)
                    }
                    .takingOwnershipOfDescriptor(input: pipe.read)
                    .get()

                // Write 1 byte to trigger read readiness
                var buf: UInt8 = 0x42
                withUnsafeBytes(of: &buf) { _ = write(pipe.write, $0.baseAddress!, 1) }

                // Wait for the handler to receive the read
                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    handler.onRead = { _ in
                        continuation.resume()
                    }
                }

                try await channel.close()
                close(pipe.write)
            }
        }

        @Test(.timed(iterations: 10, warmup: 3))
        func `wakeup channel round-trip`() async throws {
            let el = Self.fixture.eventLoop

            for _ in 0..<100 {
                let pipe = try Benchmark.Selector.makeNonBlockingPipe()
                let handler = ReadReadyHandler()

                let channel = try await NIOPipeBootstrap(group: el)
                    .channelInitializer { channel in
                        channel.pipeline.addHandler(handler)
                    }
                    .takingOwnershipOfDescriptor(input: pipe.read)
                    .get()

                // Write from a detached task to measure cross-task wakeup
                Task.detached {
                    var buf: UInt8 = 0x42
                    withUnsafeBytes(of: &buf) { _ = write(pipe.write, $0.baseAddress!, 1) }
                }

                try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, any Error>) in
                    handler.onRead = { _ in
                        continuation.resume()
                    }
                }

                try await channel.close()
                close(pipe.write)
            }
        }
    }
}

// MARK: - Helpers

extension Benchmark.Selector {

    static func makeNonBlockingPipe() throws -> (read: Int32, write: Int32) {
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { throw Errno(rawValue: errno) }
        // NIO sets non-blocking internally when registering channels
        return (read: fds[0], write: fds[1])
    }

    struct Errno: Error {
        let rawValue: Int32
    }
}

// MARK: - Fixture

extension Benchmark.Selector {

    final class Fixture: @unchecked Sendable {
        let group: MultiThreadedEventLoopGroup
        let eventLoop: any EventLoop

        static let shared = Fixture()

        init() {
            self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
            self.eventLoop = self.group.next()
        }
    }
}

// MARK: - Handler

extension Benchmark.Selector {

    /// Handler that signals readiness via a continuation.
    final class ReadReadyHandler: ChannelInboundHandler, @unchecked Sendable {
        typealias InboundIn = ByteBuffer

        var onRead: ((ByteBuffer) -> Void)?

        func channelRead(context: ChannelHandlerContext, data: NIOAny) {
            let buffer = unwrapInboundIn(data)
            onRead?(buffer)
        }
    }
}
