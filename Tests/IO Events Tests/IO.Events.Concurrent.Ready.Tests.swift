//
//  Events.Concurrent.Ready.Tests.swift
//  swift-io
//
//  P0 regression gate: two concurrent awaits on the same fd+interest must
//  both resolve correctly under the per-call channel dispatch model.
//
//  ## Shape
//
//  The Swift 6.3 region-isolation checker rejects two `async let` children
//  both borrowing a `~Copyable` `Kernel.Descriptor` from the parent frame.
//  The reproduction therefore uses the actor's internal whitebox surface:
//
//  1. Borrow `pipe.read` once at setup, passing it to
//     `Event.Actor.register(_:)`. That produces an `Event.ID`
//     (Copyable, Sendable).
//  2. Fire two `async let` children calling
//     `Event.Actor.wait(for:interest:)` on the captured
//     registration ID. All parameters are Copyable — no `~Copyable`
//     crosses the `async let` boundary.
//
//  Both calls create their own transient channel — no shared receiver,
//  no single-suspender precondition to violate.
//

import IO_Test_Support
@_spi(Syscall) import Kernel
import Memory_Primitives
import Span_Raw_Primitives
import Testing

@testable import IO_Events

@Suite(

    .disabled(
        if: Toolchain.hasTaggedMetadataSIGSEGV,
        "catalog §A9: Event.Actor() drives a real Kernel.Event.Driver whose registry is Dictionary<Kernel.Event.ID, Registration> (site 3, Kernel.Event.ID = Tagged<ISO_9945.Kernel.Event, UInt>); swift_getTypeByMangledName null-deref SIGSEGV on the first registry insert (register, via actor.register/io.write/read/ready) on compiler(<6.4). Fixed on Swift 6.4+. See swift-institute/Issues/swift-issue-tagged-dictionary-insert-metadata-crash."
    )
)
struct Test {}

// MARK: - Concurrent reproduction (whitebox)

extension IOEventsConcurrentReadyTests {

    /// Two concurrent `wait(for: registrationID, interest: .read)` calls
    /// on the SAME pre-obtained registration ID. Each creates its own
    /// transient channel — both resolve after the pre-written byte makes
    /// the read end ready (broadcast-to-all-senders on event dispatch).
    @Test
    func `two concurrent awaits on the same registration ID`() async throws {
        let actor = try Event.Actor()
        let io = IO.events(on: actor)

        let pipe = try Kernel.Pipe.pipe()
        try Kernel.File.Control.setNonBlocking(pipe.read)
        try Kernel.File.Control.setNonBlocking(pipe.write)

        // Pre-fill the pipe so that once both awaiters register,
        // readiness fires on the existing data.
        let one = UnsafeMutableRawBufferPointer.allocate(byteCount: 1, alignment: 1)
        defer { unsafe one.deallocate() }
        unsafe one[0] = 0x42
        _ = try await io.write(
            to: pipe.write,
            from: unsafe .init(UnsafeRawBufferPointer(one))
        )

        // Single borrow at setup: obtain the registration ID for
        // `pipe.read` once. After this await returns, the actor has
        // dup'd the fd and the driver owns its own copy.
        let registrationID = try await actor.register(pipe.read)

        // Two concurrent awaits on the same registration ID. Only
        // Copyable values cross the async let boundary (actor reference
        // + Event.ID + Interest) — no region-isolation rejection.
        async let first: Void = actor.wait(for: registrationID, interest: .read)
        async let second: Void = actor.wait(for: registrationID, interest: .read)
        try await first
        try await second
    }
}

// MARK: - Control: sequential readiness on the same fd

extension IOEventsConcurrentReadyTests {

    /// Control: sequential `io.ready` calls on the same fd must work both
    /// before and after the per-call channel fix. If this regresses, the
    /// fix broke the single-awaiter path. Uses the public facade.
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
