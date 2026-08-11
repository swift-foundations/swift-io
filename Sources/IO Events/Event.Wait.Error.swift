//
//  Event.Wait.Error.swift
//  swift-io
//

#if !os(Windows)
    extension Event.Wait {
        /// A typed failure from readiness, structured execution, or the
        /// domain-supplied nonblocking attempt.
        public enum Error<Failure: Swift.Error>: Swift.Error {
            case event(Event.Failure)
            case thread(Kernel.Thread.Error)
            case operation(Failure)
        }
    }

    extension Event.Wait.Error: Sendable where Failure: Sendable {}
    extension Event.Wait.Error: Equatable where Failure: Equatable {}
#endif
