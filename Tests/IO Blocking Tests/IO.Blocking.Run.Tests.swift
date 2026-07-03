//
//  Basic.Run.Tests.swift
//  swift-io
//

import IO_Test_Support
import Memory_Primitives
import Span_Raw_Primitives
import Testing

@Suite(.timeLimit(.minutes(1)))
struct IOBlockingRunTests {
    @Test
    func `read/write through pipe`() async throws {
        let io = IO.blocking()
        let pipe = try Kernel.Pipe.pipe()

        let message: [UInt8] = [72, 101, 108, 108, 111]  // "Hello"
        let writePtr = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: message.count, alignment: 1)
        defer { writePtr.deallocate() }
        unsafe writePtr.copyBytes(from: message)
        let writeBuffer: Span.Raw = unsafe .init(UnsafeRawBufferPointer(writePtr))

        let readPtr = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: 16, alignment: 1)
        defer { readPtr.deallocate() }
        let readBuffer: Span.Raw.Mutable = unsafe .init(readPtr)

        let written = try await io.write(to: pipe.write, from: writeBuffer)
        #expect(written == 5)

        let bytesRead = try await io.read(from: pipe.read, into: readBuffer)
        #expect(bytesRead == 5)

        let result = unsafe Array(UnsafeRawBufferPointer(readPtr).prefix(5))
        #expect(result == message)
    }

    @Test
    func `concurrent blocking calls complete — proves dedicated threads`() async throws {
        let count = 16
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<count {
                group.addTask {
                    let io = IO.blocking()
                    let pipe = try Kernel.Pipe.pipe()

                    let ptr = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: 1, alignment: 1)
                    defer { ptr.deallocate() }
                    unsafe ptr[0] = 42
                    let writeBuf: Span.Raw = unsafe .init(UnsafeRawBufferPointer(ptr))
                    let readBuf: Span.Raw.Mutable = unsafe .init(ptr)

                    _ = try await io.write(to: pipe.write, from: writeBuf)
                    _ = try await io.read(from: pipe.read, into: readBuf)
                }
            }
            try await group.waitForAll()
        }
    }

    @Test
    func `await between I/O calls — actor isolation keeps ops on executor`() async throws {
        // Shape B: actor isolation guarantees the executor binding. After any
        // suspension point (Task.yield, Task.sleep, @MainActor hop), the next
        // await on io.* hops back to the impl actor's executor. Running 16
        // concurrent instances exercises this without deadlocking the
        // cooperative pool.
        let count = 16
        try await withThrowingTaskGroup(of: Void.self) { group in
            for _ in 0..<count {
                group.addTask {
                    let io = IO.blocking()
                    let pipe = try Kernel.Pipe.pipe()

                    let ptr = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: 1, alignment: 1)
                    defer { ptr.deallocate() }
                    unsafe ptr[0] = 1
                    let writeBuf: Span.Raw = unsafe .init(UnsafeRawBufferPointer(ptr))
                    let readBuf: Span.Raw.Mutable = unsafe .init(ptr)

                    _ = try await io.write(to: pipe.write, from: writeBuf)
                    _ = try await io.read(from: pipe.read, into: readBuf)

                    // Suspension that previously broke TaskExecutor preference.
                    await Task.yield()

                    unsafe ptr[0] = 2
                    _ = try await io.write(to: pipe.write, from: writeBuf)
                    _ = try await io.read(from: pipe.read, into: readBuf)
                }
            }
            try await group.waitForAll()
        }
    }

    @Test
    func `errors propagate from closure through witness to caller`() async throws {
        let io = IO.blocking()
        let readPtr = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: 16, alignment: 1)
        defer { readPtr.deallocate() }
        let readBuf: Span.Raw.Mutable = unsafe .init(readPtr)

        let invalid = Kernel.Descriptor.invalid

        await #expect(throws: Basic.Error.self) {
            _ = try await io.read(from: invalid, into: readBuf)
        }
    }

    @Test
    func `IO instance is reusable across multiple calls`() async throws {
        let io = IO.blocking()

        let pipe = try Kernel.Pipe.pipe()
        let ptr = unsafe UnsafeMutableRawBufferPointer.allocate(byteCount: 1, alignment: 1)
        defer { ptr.deallocate() }
        let writeBuf: Span.Raw = unsafe .init(UnsafeRawBufferPointer(ptr))
        let readBuf: Span.Raw.Mutable = unsafe .init(ptr)

        unsafe ptr[0] = 1
        _ = try await io.write(to: pipe.write, from: writeBuf)
        _ = try await io.read(from: pipe.read, into: readBuf)

        unsafe ptr[0] = 2
        _ = try await io.write(to: pipe.write, from: writeBuf)
        _ = try await io.read(from: pipe.read, into: readBuf)
    }
}
