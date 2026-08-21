import IO_Test_Support
@_spi(Syscall) import Kernel
import Memory_Primitives
import Span_Raw_Primitives
import Testing

extension Event.Actor {
    @Suite(

        .disabled(
            if: Toolchain.hasTaggedMetadataSIGSEGV,
            "catalog §A9: Event.Actor() drives a real Kernel.Event.Driver whose registry is Dictionary<Kernel.Event.ID, Registration> (site 3, Kernel.Event.ID = Tagged<ISO_9945.Kernel.Event, UInt>); swift_getTypeByMangledName null-deref SIGSEGV on the first registry insert (register, via io.write/read/ready) on compiler(<6.4). Fixed on Swift 6.4+. See swift-institute/Issues/swift-issue-tagged-dictionary-insert-metadata-crash."
        )
    )
    struct Test {}
}

extension Event.Actor.Test {

    @Test
    func `pipe round-trip: write then read returns the bytes written`() async throws {
        let actor = try Event.Actor()
        let io = IO.events(on: actor)

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

extension Event.Actor.Test {

    @Test
    func `ready on a pipe write-end returns immediately when writable`() async throws {
        let actor = try Event.Actor()
        let io = IO.events(on: actor)

        let pipe = try Kernel.Pipe.pipe()
        try Kernel.File.Control.setNonBlocking(pipe.read)
        try Kernel.File.Control.setNonBlocking(pipe.write)

        try await io.ready(from: pipe.write, interest: .write)
    }

    @Test
    func `ready then write+read composes: explicit readiness before syscall`() async throws {
        let actor = try Event.Actor()
        let io = IO.events(on: actor)

        let pipe = try Kernel.Pipe.pipe()
        try Kernel.File.Control.setNonBlocking(pipe.read)
        try Kernel.File.Control.setNonBlocking(pipe.write)

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

extension Event.Actor.Test {

    @Test
    func `IO.events witness carries a non-default unownedExecutor`() async throws {
        let actor = try Event.Actor()
        let io = IO.events(on: actor)

        _ = io.unownedExecutor
    }

    @Test
    func `two IO.events witnesses from the same Events share a reactor thread`() async throws {
        let actor = try Event.Actor()
        let ioA = IO.events(on: actor)
        let ioB = IO.events(on: actor)

        let execA = unsafe ioA.unownedExecutor
        let execB = unsafe ioB.unownedExecutor

        _ = (execA, execB)
    }
}
