//
//  Event.Wait.swift
//  swift-io
//

#if !os(Windows)
    extension Event {
        /// Namespace for the Event strategy's one-shot readiness wait.
        public enum Wait: Sendable {}
    }
#endif
