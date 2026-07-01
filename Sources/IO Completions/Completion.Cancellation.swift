//
//  Completion.Cancellation.swift
//  swift-io
//

import Synchronization

extension Completion {
    /// Cancellation intent flag shared between the actor's submit path
    /// and an `onCancel` handler.
    ///
    /// Written once by the client's `onCancel` handler (arbitrary
    /// thread), read by the Completion executor's tick during the
    /// cancellation-check phase.
    ///
    /// ## Thread Safety
    ///
    /// `Sendable`: internal `Atomic<Bool>` provides synchronization.
    /// Shared between ``IO/Completion/Entry`` (held by the executor's
    /// tick) and the `onCancel` handler (called from arbitrary thread).
    ///
    /// ## Why a Class
    ///
    /// `Atomic<Bool>` is `~Copyable`, so it cannot be directly embedded
    /// in a value type that is both held by the entry and captured by
    /// an `onCancel` closure. A reference type wrapper is required for
    /// sharing.
    ///
    /// ## Naming
    ///
    /// The type IS the namespace per [API-NAME-001a] / [IMPL-084] —
    /// there is exactly one cancellation primitive in this domain, so
    /// it does not nest under a `Cancellation.*` variant label. Read
    /// `Completion.Cancellation` as "the cancellation token of an
    /// in-flight completion operation."
    public final class Cancellation: Sendable {
        private let _value = Atomic<Bool>(false)

        public init() {}

        deinit {}
    }
}

// MARK: - Operations

extension Completion.Cancellation {
    /// Sets the cancellation flag.
    ///
    /// Called from the client's `onCancel` handler. Write-once —
    /// subsequent calls are harmless no-ops.
    public func set() {
        _value.store(true, ordering: .releasing)
    }

    /// Whether cancellation has been requested.
    ///
    /// Read by the Completion executor's tick during the
    /// cancellation-check phase.
    public var isSet: Bool {
        _value.load(ordering: .acquiring)
    }
}
