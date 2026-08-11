//
//  Event.Operation.Error.swift
//  swift-io
//

#if !os(Windows)
    extension Event.Operation {
        /// A failure from one phase of a cancellable event operation.
        public enum Error<Failure: Swift.Error>: Swift.Error {
            /// The readiness lifecycle was cancelled, shut down, or timed out.
            case lifecycle(Async.Lifecycle.Error)

            /// The event source could not register, arm, wait, or deregister.
            case event(Event.Error)

            /// The structured worker thread could not be created or joined.
            case thread(Kernel.Thread.Error)

            /// The caller's nonblocking attempt failed.
            case operation(Failure)
        }
    }

    extension Event.Operation.Error: Sendable where Failure: Sendable {}
    extension Event.Operation.Error: Equatable where Failure: Equatable {}
#endif
