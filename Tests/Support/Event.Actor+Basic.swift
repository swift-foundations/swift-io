//
//  Event.Actor+Basic.swift
//  IO Test Support
//
//  Basic-domain (fd byte-ops) operations on the events-strategy actor.
//  Built on the reactor primitives `register(_:)`, `wait(for:interest:)`,
//  and `deregister(_:)` from swift-io's IO Events module. Each domain
//  (Basic, File, Socket, Server) contributes its own extensions here;
//  the reactor itself stays domain-agnostic.
//

public import IO
@_spi(Syscall) public import Kernel
public import Span_Raw_Primitives

extension Event.Actor {

    /// Read bytes from `fd` into `buffer`, arming the reactor on
    /// `EAGAIN`.
    public func read(
        from fd: borrowing Kernel.Descriptor,
        into buffer: Span.Raw.Mutable
    ) async throws(Event.Failure) -> Int {
        let registrationID: Event.ID = try register(fd)
        while true {
            do throws(Kernel.IO.Read.Error) {
                return try unsafe Kernel.IO.Read.read(fd, into: unsafe buffer.base.nonNull)
            } catch .blocking(.wouldBlock) {
                try await wait(for: registrationID, interest: .read)
            } catch {
                throw .right(error.eventError)
            }
        }
    }

    /// Write bytes from `buffer` to `fd`, arming the reactor on `EAGAIN`.
    public func write(
        to fd: borrowing Kernel.Descriptor,
        from buffer: Span.Raw
    ) async throws(Event.Failure) -> Int {
        let registrationID: Event.ID = try register(fd)
        while true {
            do throws(Kernel.IO.Write.Error) {
                return try unsafe Kernel.IO.Write.write(fd, from: unsafe buffer.base.nonNull)
            } catch .blocking(.wouldBlock) {
                try await wait(for: registrationID, interest: .write)
            } catch {
                throw .right(error.eventError)
            }
        }
    }

    /// Wait for `fd` to become ready for the requested interest.
    public func ready(
        from fd: borrowing Kernel.Descriptor,
        interest: Kernel.Event.Interest
    ) async throws(Event.Failure) {
        let registrationID: Event.ID = try register(fd)
        try await wait(for: registrationID, interest: interest)
    }

    /// Close `fd`. Deregisters from the reactor, then invokes `close(2)`.
    public func close(_ fd: consuming Kernel.Descriptor) async {
        deregister(Kernel.Event.ID(descriptor: fd))
        do throws(Kernel.Close.Error) {
            try Kernel.Close.close(consume fd)
        } catch {}
    }
}
