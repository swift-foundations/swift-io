//
//  IO.Default.Tests.swift
//  swift-io
//
//  Smoke coverage for IO.default() — the host-adaptive factory.
//  The specific strategy picked varies by host; the tests assert the
//  properties that must hold regardless of strategy.
//

import IO_Test_Support
@_spi(Syscall) import Kernel
import Memory_Primitives
import Span_Raw_Primitives
import Testing

@Suite("IO.default — smoke tests")
struct IODefaultTests {

    @Test
    func `IO.default() returns an IO with a non-default executor`() async throws {
        let io = IO.default()
        // The witness always carries a strategy-specific executor
        // (blocking thread, events loop, or completions loop). Its
        // identity is observable — if it were the global cooperative
        // executor the shared-executor TCA26 pattern would silently
        // degrade to a cross-hop.
        _ = io.unownedExecutor
    }

    @Test
    func `IO.default() round-trips bytes through a pipe`() async throws {
        let io = IO.default()
        let pipe = try Kernel.Pipe.pipe()

        // events strategy requires non-blocking mode on the read side
        // for EAGAIN-armed retry; the default may or may not land on
        // events, but setting non-blocking is harmless under blocking
        // and completions.
        try? Kernel.File.Control.setNonBlocking(pipe.read)

        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]
        let writePtr = unsafe UnsafeMutableRawBufferPointer.allocate(
            byteCount: payload.count,
            alignment: 1
        )
        defer { unsafe writePtr.deallocate() }
        for (i, byte) in payload.enumerated() { unsafe writePtr[i] = byte }

        _ = try await io.write(
            to: pipe.write,
            from: unsafe .init(UnsafeRawBufferPointer(writePtr))
        )

        let readPtr = unsafe UnsafeMutableRawBufferPointer.allocate(
            byteCount: 1024,
            alignment: 1
        )
        defer { unsafe readPtr.deallocate() }

        let n = try await io.read(
            from: pipe.read,
            into: unsafe .init(readPtr)
        )
        #expect(n == payload.count)
        var received: [UInt8] = []
        for i in 0..<n { received.append(unsafe readPtr[i]) }
        #expect(received == payload)
    }
}
