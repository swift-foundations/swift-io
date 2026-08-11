//
//  Event.Operation.swift
//  swift-io
//

#if !os(Windows)
    extension Event {
        /// Namespace for one-shot cancellable readiness operations.
        ///
        /// Operations borrow a descriptor for their complete dynamic extent.
        /// They wait through the event strategy, perform one nonblocking
        /// attempt on a structured Kernel thread, physically join it, remove
        /// the exact registration, and only then return to the borrower.
        public enum Operation: Sendable {}
    }
#endif
