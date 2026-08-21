import IO_Test_Support
@_spi(Syscall) import Kernel
import Memory_Primitives
import Span_Raw_Primitives
import Testing

@testable import IO_Events

extension Event.Actor {
    @Suite(

        .disabled(
            if: Toolchain.hasTaggedMetadataSIGSEGV,
            "catalog §A9: Event.Actor() drives a real Kernel.Event.Driver whose registry is Dictionary<Kernel.Event.ID, Registration> (site 3, Kernel.Event.ID = Tagged<ISO_9945.Kernel.Event, UInt>); swift_getTypeByMangledName null-deref SIGSEGV on the first registry insert (register, via actor.register/io.write/read/ready) on compiler(<6.4). Fixed on Swift 6.4+. See swift-institute/Issues/swift-issue-tagged-dictionary-insert-metadata-crash."
        )
    )
    struct `Concurrent Ready` {}
}

extension Event.Actor.`Concurrent Ready` {

    @Test
    func `two concurrent awaits on the same registration ID`() async throws {
        let actor = try Event.Actor()
        let io = IO.events(on: actor)

        let pipe = try Kernel.Pipe.pipe()
        try Kernel.File.Control.setNonBlocking(pipe.read)
        try Kernel.File.Control.setNonBlocking(pipe.write)

        let one = UnsafeMutableRawBufferPointer.allocate(byteCount: 1, alignment: 1)
        defer { unsafe one.deallocate() }
        unsafe one[0] = 0x42
        _ = try await io.write(
            to: pipe.write,
            from: unsafe .init(UnsafeRawBufferPointer(one))
        )

        let registrationID = try await actor.register(pipe.read)

        async let first: Void = actor.wait(for: registrationID, interest: .read)
        async let second: Void = actor.wait(for: registrationID, interest: .read)
        try await first
        try await second
    }
}

extension Event.Actor.`Concurrent Ready` {

    @Test
    func `sequential io.ready calls on the same fd`() async throws {
        let actor = try Event.Actor()
        let io = IO.events(on: actor)

        let pipe = try Kernel.Pipe.pipe()
        try Kernel.File.Control.setNonBlocking(pipe.read)
        try Kernel.File.Control.setNonBlocking(pipe.write)

        let one = UnsafeMutableRawBufferPointer.allocate(byteCount: 1, alignment: 1)
        defer { unsafe one.deallocate() }

        unsafe one[0] = 0x01
        _ = try await io.write(
            to: pipe.write,
            from: unsafe .init(UnsafeRawBufferPointer(one))
        )
        try await io.ready(from: pipe.read, interest: .read)
        _ = try await io.read(
            from: pipe.read,
            into: unsafe .init(one)
        )

        unsafe one[0] = 0x02
        _ = try await io.write(
            to: pipe.write,
            from: unsafe .init(UnsafeRawBufferPointer(one))
        )
        try await io.ready(from: pipe.read, interest: .read)
        _ = try await io.read(
            from: pipe.read,
            into: unsafe .init(one)
        )
    }
}
