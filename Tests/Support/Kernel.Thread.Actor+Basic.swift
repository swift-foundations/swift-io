//
//  Kernel.Thread.Actor+Basic.swift
//  swift-io
//
//  Basic byte-ops syscall bindings attached to Kernel.Thread.Actor
//  (swift-threads). Actor isolation guarantees each method runs on the
//  actor's pinned OS thread.
//
//  These extensions are what decomposes the former `IO Blocking` module:
//  the pinned-actor pattern lives in swift-threads as Kernel.Thread.Actor;
//  swift-io attaches the basic syscall set here; the factory pairs them
//  with a Runner to produce an `IO<Basic.Capabilities>`.
//

public import Span_Raw_Primitives

extension Kernel.Thread.Actor {

    /// Read bytes from `descriptor` into `buffer` on the actor's pinned
    /// OS thread. Returns bytes read, or 0 at EOF.
    public func read(
        from descriptor: borrowing Kernel.Descriptor,
        into buffer: Span.Raw.Mutable
    ) throws(Basic.Error) -> Int {
        do throws(Kernel.IO.Read.Error) {
            return try unsafe Kernel.IO.Read.read(descriptor, into: unsafe buffer.base.nonNull)
        } catch {
            throw error.basicError
        }
    }

    /// Write bytes from `buffer` to `descriptor` on the actor's pinned
    /// OS thread. Returns bytes written.
    public func write(
        to descriptor: borrowing Kernel.Descriptor,
        from buffer: Span.Raw
    ) throws(Basic.Error) -> Int {
        do throws(Kernel.IO.Write.Error) {
            return try unsafe Kernel.IO.Write.write(descriptor, from: unsafe buffer.base.nonNull)
        } catch {
            throw error.basicError
        }
    }

    /// Close `descriptor` on the actor's pinned OS thread.
    ///
    /// Close errors are swallowed — the fd is closed at the kernel
    /// level even when the syscall reports an error, and close errors
    /// (e.g., EINTR on NFS) are rarely actionable.
    public func close(_ descriptor: consuming Kernel.Descriptor) {
        do throws(Kernel.Close.Error) {
            try Kernel.Close.close(consume descriptor)
        } catch {
            // fd is already closed — error is informational only.
        }
    }

    // MARK: - Test support

    /// The OS thread this actor is pinned to.
    ///
    /// Accessed via `await actor.id`; the isolation hop guarantees the
    /// sampling runs on the executor's dedicated thread. Used by tests
    /// to assert that two IOs sharing one `Kernel.Thread.Executor` land
    /// on the same OS thread, and that two IOs with distinct executors
    /// land on different ones.
    public var id: Kernel.Thread.ID { Kernel.Thread.ID.current }
}
