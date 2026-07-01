//
//  Basic.Capabilities.swift
//  swift-io
//

public import Span_Raw_Primitives

extension Basic {
    /// Basic byte-ops capability surface for ``Kernel/Descriptor``.
    ///
    /// Four `@Sendable` closures describing the operations that any
    /// strategy (blocking / events / completions) must provide. Each
    /// per-strategy factory constructs a value of this struct and pairs
    /// it with an ``IO/Runner`` via ``IO``'s initializer.
    ///
    /// ## Buffer Ownership
    ///
    /// The ``Span/Raw`` / ``Span/Raw/Mutable`` parameters
    /// passed to `read` / `write` are **non-owning views**. The caller
    /// guarantees the referred memory remains at a stable address for
    /// the duration of the enclosing `try await` expression.
    ///
    /// The proactor strategy is where this contract has teeth — the
    /// kernel holds the buffer pointer from SQE submission through CQE
    /// consumption. On task cancellation the factory submits
    /// `IORING_OP_ASYNC_CANCEL` and waits for BOTH the original SQE's
    /// CQE and the cancel CQE before unwinding.
    public struct Capabilities: Sendable {

        /// Read bytes from a descriptor into a mutable buffer. Returns
        /// bytes read, or 0 at EOF.
        public let read: @Sendable (
            borrowing Kernel.Descriptor,
            Span.Raw.Mutable
        ) async throws(Basic.Error) -> Int

        /// Write bytes from a buffer to a descriptor. Returns bytes
        /// written.
        public let write: @Sendable (
            borrowing Kernel.Descriptor,
            Span.Raw
        ) async throws(Basic.Error) -> Int

        /// Close a descriptor. Ownership is consumed.
        public let close: @Sendable (consuming Kernel.Descriptor) async -> Void

        /// Wait for a descriptor to become ready for the requested
        /// interest.
        ///
        /// Readiness composition primitive. Consumers use this to pre-
        /// wait before issuing a domain-specific syscall that is not
        /// part of the capability set (e.g., `Kernel.Socket.Accept.accept`
        /// after `ready(listener, .read)`).
        ///
        /// Strategy semantics:
        ///
        /// - **Blocking** — no-op. The subsequent syscall is the actual
        ///   block; the executor thread waits there. Ready-then-syscall
        ///   composes correctly with a no-op ready.
        /// - **Events (reactor)** — register the fd and await the
        ///   kernel readiness event. The fd MUST be in non-blocking
        ///   mode so the subsequent syscall returns immediately when
        ///   readiness is signalled.
        /// - **Completions (proactor)** — submit `IORING_OP_POLL_ADD`
        ///   (or platform equivalent) and await the CQE.
        public let ready: @Sendable (
            borrowing Kernel.Descriptor,
            Kernel.Event.Interest
        ) async throws(Basic.Error) -> Void

        /// Creates a capability set from its four operation closures.
        public init(
            read: @Sendable @escaping (
                borrowing Kernel.Descriptor,
                Span.Raw.Mutable
            ) async throws(Basic.Error) -> Int,
            write: @Sendable @escaping (
                borrowing Kernel.Descriptor,
                Span.Raw
            ) async throws(Basic.Error) -> Int,
            close: @Sendable @escaping (consuming Kernel.Descriptor) async -> Void,
            ready: @Sendable @escaping (
                borrowing Kernel.Descriptor,
                Kernel.Event.Interest
            ) async throws(Basic.Error) -> Void
        ) {
            self.read = read
            self.write = write
            self.close = close
            self.ready = ready
        }
    }
}
