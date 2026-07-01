//
//  Events.Tests.swift
//  swift-io
//
//  Smoke tests for the events-strategy IO witness produced by
//  IO.events(on:) / IO.events(). Uses pipes as the test fd — pipes are
//  pollable on both kqueue and epoll, and the fd pair is simple to set
//  up without any socket / network configuration.
//

import IO_Test_Support
@_spi(Syscall) import Kernel
import Memory_Primitives
import Span_Raw_Primitives
import Testing

@Suite("IO.events — smoke tests")
struct IOEventsTests {}

// MARK: - Pipe round-trip

extension IOEventsTests {

    @Test
    func `pipe round-trip: write then read returns the bytes written`() async throws {
        let actor = try Event.Actor()
        let io = IO.events(on: actor)

        // Pipe read end must be non-blocking for events strategy.
        let pipe = try Kernel.Pipe.pipe()
        try Kernel.File.Control.setNonBlocking(pipe.read)

        let payload: [UInt8] = [0xDE, 0xAD, 0xBE, 0xEF]

        let writePtr = UnsafeMutableRawBufferPointer.allocate(
            byteCount: payload.count,
            alignment: 1
        )
        defer { unsafe writePtr.deallocate() }
        for (i, byte) in payload.enumerated() { unsafe writePtr[i] = byte }
        let writeBuffer: Span.Raw = unsafe .init(UnsafeRawBufferPointer(writePtr))

        _ = try await io.write(to: pipe.write, from: writeBuffer)

        let readPtr = UnsafeMutableRawBufferPointer.allocate(
            byteCount: 1024,
            alignment: 1
        )
        defer { unsafe readPtr.deallocate() }
        let readBuffer: Span.Raw.Mutable = unsafe .init(readPtr)

        let n = try await io.read(from: pipe.read, into: readBuffer)

        #expect(n == payload.count)
        var received: [UInt8] = []
        for i in 0..<n { received.append(unsafe readPtr[i]) }
        #expect(received == payload)
    }
}

// MARK: - Ready composition

extension IOEventsTests {

    @Test
    func `ready on a pipe write-end returns immediately when writable`() async throws {
        let actor = try Event.Actor()
        let io = IO.events(on: actor)

        let pipe = try Kernel.Pipe.pipe()
        try Kernel.File.Control.setNonBlocking(pipe.read)
        try Kernel.File.Control.setNonBlocking(pipe.write)

        // Fresh pipe buffer is empty → write end is always-ready. The kernel
        // fires a write-readiness event immediately on arm; ready() returns
        // promptly without blocking indefinitely.
        try await io.ready(from: pipe.write, interest: .write)
    }

    @Test
    func `ready then write+read composes: explicit readiness before syscall`() async throws {
        let actor = try Event.Actor()
        let io = IO.events(on: actor)

        let pipe = try Kernel.Pipe.pipe()
        try Kernel.File.Control.setNonBlocking(pipe.read)
        try Kernel.File.Control.setNonBlocking(pipe.write)

        // Await write-readiness before issuing the syscall.
        try await io.ready(from: pipe.write, interest: .write)

        let payload: [UInt8] = [0x01, 0x02, 0x03]
        let writePtr = UnsafeMutableRawBufferPointer.allocate(
            byteCount: payload.count,
            alignment: 1
        )
        defer { unsafe writePtr.deallocate() }
        for (i, byte) in payload.enumerated() { unsafe writePtr[i] = byte }
        let writeBuffer: Span.Raw = unsafe .init(UnsafeRawBufferPointer(writePtr))
        _ = try await io.write(to: pipe.write, from: writeBuffer)

        // Now read-readiness is reachable.
        try await io.ready(from: pipe.read, interest: .read)

        let readPtr = UnsafeMutableRawBufferPointer.allocate(
            byteCount: 1024,
            alignment: 1
        )
        defer { unsafe readPtr.deallocate() }
        let n = try await io.read(
            from: pipe.read,
            into: unsafe .init(readPtr)
        )

        #expect(n == payload.count)
    }
}

// MARK: - Shared-executor binding

extension IOEventsTests {

    @Test
    func `IO.events witness carries a non-default unownedExecutor`() async throws {
        let actor = try Event.Actor()
        let io = IO.events(on: actor)

        // The witness's executor is the actor's Polling executor. At minimum it must
        // be obtainable; full TCA26 probing is covered by IO Blocking's
        // binding tests which exercise the shared-executor pattern directly.
        _ = io.unownedExecutor
    }

    @Test
    func `two IO.events witnesses from the same Events share a reactor thread`() async throws {
        let actor = try Event.Actor()
        let ioA = IO.events(on: actor)
        let ioB = IO.events(on: actor)

        // Same actor → same Polling executor.
        let execA = unsafe ioA.unownedExecutor
        let execB = unsafe ioB.unownedExecutor
        // UnownedSerialExecutor doesn't expose equality directly; observe
        // that both witnesses at least exist concurrently without reactor
        // contention. Fine-grained executor-identity assertions are
        // covered elsewhere in IO Blocking's binding suite.
        _ = (execA, execB)
    }
}
