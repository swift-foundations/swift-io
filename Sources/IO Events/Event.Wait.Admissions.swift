//
//  Event.Wait.Admissions.swift
//  swift-io
//

#if !os(Windows)
    import Synchronization

    extension Event.Wait {
        /// Thread-safe handoff from synchronous callers to Event.Actor.
        final class Admissions: Sendable {
            private let state = Mutex((accepting: true, pending: [Event.Wait.State]()))
        }
    }

    extension Event.Wait.Admissions {
        func append(_ wait: Event.Wait.State) -> Bool {
            state.withLock { state in
                guard state.accepting else { return false }
                state.pending.append(wait)
                return true
            }
        }

        func drain() -> [Event.Wait.State] {
            state.withLock { state in
                let admitted = state.pending
                state.pending.removeAll()
                return admitted
            }
        }

        func close() -> [Event.Wait.State] {
            state.withLock { state in
                state.accepting = false
                let rejected = state.pending
                state.pending.removeAll()
                return rejected
            }
        }
    }
#endif
