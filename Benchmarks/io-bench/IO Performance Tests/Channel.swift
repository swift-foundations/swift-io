//
//  Channel.swift
//  swift-io / Benchmarks / io-bench
//
//  Measures non-blocking I/O throughput via IO.Event.Channel over socket pairs.
//  Mirror of nio-bench with identical workloads and test names.
//

import IO
import IO_Blocking
import IO_Blocking_Threads
import IO_Test_Support
import Kernel
import IO_Events
import Testing

extension Benchmark {

    @Suite struct Channel {

        /// Dedicated lane for raw-fd blocking I/O in Channel benchmarks.
        static let blockingLane: IO.Blocking.Lane = {
            IO.Blocking.Lane.threads(IO.Blocking.Threads.Options(workers: 1))
        }()
    }
}

// MARK: - Performance

extension Benchmark.Channel {

    static let messageSize = 64
    static let roundTrips = 1000
    static let bulkSize = 1024 * 1024  // 1 MB

    @Test(.timed(iterations: 5, warmup: 1))
    func `echo 1000 round-trips 64B messages`() async throws {
        let selector = try await IO.Event.Selector.shared()
        var sockets = try Kernel.Socket.Pair.create()

        // Extract owning descriptors — setNonBlocking borrows, wrap consumes.
        var channelDesc = Kernel.Descriptor(sockets.first)
        var peerDesc = Kernel.Descriptor(sockets.second)
        try Kernel.File.Control.setNonBlocking(channelDesc)

        // Split for concurrent read/write — pipelined writes exceeding the
        // AF_UNIX socket buffer (~8 KB) deadlock without full-duplex because
        // the echo driver blocks on write when the receive buffer fills.
        let channel = try await IO.Event.Channel(
            channelDesc,
            selector: selector,
            interest: [.read, .write]
        )

        var split = channel.split()
        var reader = split.reader()
        var writer = split.writer()

        // Echo driver: sync enqueue to dedicated OS thread.
        // Captures peerDesc by consuming — deinit closes fd when worker finishes.
        let echoHandle = try Self.blockingLane.run.sync { [peerDesc] in
            do {
                let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: Self.messageSize, alignment: 1)
                defer { unsafe buf.deallocate() }
                for _ in 0..<Self.roundTrips {
                    var totalRead = 0
                    while totalRead < Self.messageSize {
                        let n = try unsafe Kernel.IO.Read.read(
                            peerDesc,
                            into: UnsafeMutableRawBufferPointer(
                                start: unsafe buf.baseAddress!.advanced(by: totalRead),
                                count: Self.messageSize - totalRead
                            )
                        )
                        totalRead += n
                    }
                    var totalWritten = 0
                    while totalWritten < Self.messageSize {
                        let n = try unsafe Kernel.IO.Write.write(
                            peerDesc,
                            from: UnsafeRawBufferPointer(
                                start: unsafe buf.baseAddress!.advanced(by: totalWritten),
                                count: totalRead - totalWritten
                            )
                        )
                        totalWritten += n
                    }
                }
            } catch {
                preconditionFailure("Echo driver I/O failed: \(error)")
            }
        }

        // Transfer ~Copyable Writer across @Sendable boundary via
        // Ownership.Transfer.Value.Outgoing (ecosystem primitive for this pattern).
        // Local generic helper avoids having to spell the Writer type at the
        // nested-generic call site (Ownership.Transfer.Value<V>.Outgoing must
        // take V explicitly per Swift 6.3.1; the helper infers V from the arg).
        func _makeOutgoing<V: ~Copyable>(_ value: consuming V) -> Ownership.Transfer.Value<V>.Outgoing {
            Ownership.Transfer.Value<V>.Outgoing(value)
        }
        let cell = _makeOutgoing(consume writer)
        let token = cell.token()

        // Write task: pipeline all messages concurrently with reading.
        let writeTask = Task.detached {
            var writer = token.take()
            let writeBuf = [UInt8](repeating: 0xAB, count: Self.messageSize)

            for _ in 0..<Self.roundTrips {
                var totalWritten = 0
                while totalWritten < Self.messageSize {
                    let n = try await writer.write(
                        writeBuf.span.extracting(droppingFirst: totalWritten)
                    )
                    totalWritten += n
                }
            }
            try await writer.close()
        }

        // Read all echoed data (current task)
        var readBuf = [UInt8](repeating: 0, count: Self.messageSize)

        let totalEchoBytes = Self.messageSize * Self.roundTrips
        var totalRead = 0
        while totalRead < totalEchoBytes {
            var span = readBuf.mutableSpan
            let n = try await reader.read(into: &span)
            totalRead += n
        }

        _ = try await echoHandle.value()
        _ = try await writeTask.value
        try await reader.close()
    }

    @Test(.timed(iterations: 5, warmup: 1))
    func `read throughput 1MB`() async throws {
        let selector = try await IO.Event.Selector.shared()
        var sockets = try Kernel.Socket.Pair.create()

        var channelDesc = Kernel.Descriptor(sockets.first)
        var peerDesc = Kernel.Descriptor(sockets.second)
        try Kernel.File.Control.setNonBlocking(channelDesc)

        var channel = try await IO.Event.Channel(
            channelDesc,
            selector: selector,
            interest: .read
        )

        let chunkSize = 16384

        // Writer: push 1MB in chunks on the peer fd (dedicated OS thread)
        let writerHandle = try Self.blockingLane.run.sync { [peerDesc] in
            do {
                let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 1)
                defer { unsafe buf.deallocate() }
                unsafe buf.initializeMemory(as: UInt8.self, repeating: 0xFF)

                var remaining = Self.bulkSize
                while remaining > 0 {
                    let toWrite = min(remaining, chunkSize)
                    let n = try unsafe Kernel.IO.Write.write(
                        peerDesc,
                        from: UnsafeRawBufferPointer(start: buf.baseAddress!, count: toWrite)
                    )
                    remaining -= n
                }
            } catch {
                preconditionFailure("Writer I/O failed: \(error)")
            }
        }

        // Reader: channel reads until 1MB consumed
        var readBuf = [UInt8](repeating: 0, count: chunkSize)

        var totalRead = 0
        while totalRead < Self.bulkSize {
            var span = readBuf.mutableSpan
            let n = try await channel.read(into: &span)
            totalRead += n
        }

        _ = try await writerHandle.value()
        try await channel.close()
    }

    @Test(.timed(iterations: 5, warmup: 1))
    func `write throughput 1MB`() async throws {
        let selector = try await IO.Event.Selector.shared()
        var sockets = try Kernel.Socket.Pair.create()

        var channelDesc = Kernel.Descriptor(sockets.first)
        var peerDesc = Kernel.Descriptor(sockets.second)
        try Kernel.File.Control.setNonBlocking(channelDesc)

        var channel = try await IO.Event.Channel(
            channelDesc,
            selector: selector,
            interest: .write
        )

        let chunkSize = 16384

        // Reader: drain reads on peer fd (dedicated OS thread)
        let readerHandle = try Self.blockingLane.run.sync { [peerDesc] in
            do {
                let buf = UnsafeMutableRawBufferPointer.allocate(byteCount: chunkSize, alignment: 1)
                defer { unsafe buf.deallocate() }

                var totalRead = 0
                while totalRead < Self.bulkSize {
                    let n = try unsafe Kernel.IO.Read.read(
                        peerDesc,
                        into: buf
                    )
                    totalRead += n
                }
            } catch {
                preconditionFailure("Reader I/O failed: \(error)")
            }
        }

        // Writer: channel writes 1MB
        let writeBuf = [UInt8](repeating: 0xFF, count: chunkSize)

        var totalWritten = 0
        while totalWritten < Self.bulkSize {
            let toWrite = min(Self.bulkSize - totalWritten, chunkSize)
            let n = try await channel.write(
                writeBuf.span.extracting(0..<toWrite)
            )
            totalWritten += n
        }

        _ = try await readerHandle.value()
        try await channel.close()
    }
}
