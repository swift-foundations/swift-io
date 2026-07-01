//
//  Completion.Entry.swift
//  swift-io
//

import Kernel_Completion

extension Completion {
    /// Authoritative in-flight record for a completion operation.
    ///
    /// Created by an actor method on the Completion executor's thread
    /// and stored in ``IO/Completion/Actor``'s entries table. Never
    /// shared — confined to the executor's thread. Not `Sendable`.
    ///
    /// Entry holds exactly the per-operation state the actor owns:
    /// the correlation token (dictionary key + submission user_data),
    /// the operation descriptor (opcode with associated data), the
    /// dup'd target descriptor, the cancellation flag, and the
    /// continuation. Per-opcode data (buffer address/length, file
    /// offset, poll interest, cancel target) lives in the opcode's
    /// associated values — not as parallel fields.
    ///
    /// ## Terminal Law
    ///
    /// The first resolution the dispatch path commits wins. Once
    /// `resolve()` is called, the entry is consumed and cannot be
    /// resolved again.
    ///
    /// ## Three-Layer Enforcement
    ///
    /// 1. `~Copyable` prevents duplicate entries (compile time)
    /// 2. `consuming func resolve()` prevents double resolution (compile time)
    /// 3. `deinit` traps on unresolved entries (runtime safety net)
    ///
    /// ## Descriptor Ownership
    ///
    /// The dup'd descriptor lives here. The entries dictionary keeps
    /// it alive across the kernel's custody window (SQE submission
    /// through CQE arrival). When the entry is resolved and consumed,
    /// the descriptor is dropped and the fd is closed — the kernel has
    /// released it by then (CQE posted).
    ///
    /// ## Buffer Ownership
    ///
    /// The buffer is a **non-owning view** carried inside `opcode`'s
    /// associated values (`Memory.Address` + `Memory.Address.Count`).
    /// The caller guarantees the pointer is valid for the duration of
    /// the enclosing `try await` expression per the buffer-ownership
    /// contract.
    ///
    /// ## resume() Safety
    ///
    /// Direct `CheckedContinuation<Kernel.Completion.Event?, Never>.resume()`
    /// from the executor's thread. Resume enqueues the task to its
    /// executor — does not run inline on the executor thread.
    public struct Entry: ~Copyable {
        /// The operation token (correlation ID).
        ///
        /// Counter-based. Used as both the dictionary key and the
        /// submission token the kernel echoes back in the CQE.
        public let id: Kernel.Completion.Token

        /// The operation descriptor — carries per-opcode data as
        /// associated values.
        public let opcode: Kernel.Completion.Submission.Opcode

        /// Owned (duplicated) descriptor for this operation.
        ///
        /// Operations that target an fd (read, write, accept, connect,
        /// close, fsync) store a dup'd copy here. The dup is created
        /// at operation factory time and closed automatically when
        /// the entry is consumed (resolved). This avoids aliasing
        /// the caller's owned `Kernel.Descriptor`.
        ///
        /// `nil` for operations that don't target an fd (nop, cancel,
        /// wakeup).
        @usableFromInline
        var descriptor: Kernel.Descriptor?

        /// The cancellation flag (shared with the client's onCancel handler).
        public let flag: Completion.Cancellation

        /// The continuation to resume when resolved.
        /// `nil` after `resolve()` — deinit checks this to detect leaked entries.
        var _continuation: CheckedContinuation<Kernel.Completion.Event?, Never>?

        /// Creates an entry.
        public init(
            id: Kernel.Completion.Token,
            opcode: Kernel.Completion.Submission.Opcode,
            descriptor: consuming Kernel.Descriptor?,
            flag: Completion.Cancellation,
            continuation: CheckedContinuation<Kernel.Completion.Event?, Never>
        ) {
            self.id = id
            self.opcode = opcode
            self.descriptor = descriptor
            self.flag = flag
            self._continuation = continuation
        }

        deinit {
            guard let continuation = _continuation else { return }
            // Emergency: entry dropped without being resolved.
            // Resume so the waiting task doesn't hang, then trap.
            continuation.resume(returning: nil)
            preconditionFailure("Completion.Entry dropped without being resolved")
        }
    }
}

// MARK: - Resolve

extension Completion.Entry {
    /// Resolves this entry with a raw kernel completion event.
    ///
    /// Resumes the continuation with the event. The consumer's
    /// `mapEvent` closure interprets the raw event per [IMPL-092].
    public consuming func resolve(with event: Kernel.Completion.Event) {
        _continuation!.resume(returning: event)
        _continuation = nil
    }

    /// Resolves this entry as cancelled.
    ///
    /// Resumes the continuation with `nil` — the consumer observes
    /// the absence and throws `Basic.Error.cancelled`.
    public consuming func resolveAsCancelled() {
        _continuation!.resume(returning: nil)
        _continuation = nil
    }
}
