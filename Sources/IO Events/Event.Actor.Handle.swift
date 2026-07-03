//
//  Event.Actor.Handle.swift
//  swift-io
//
//  Class-typed weak back-reference from the Polling tick closure to
//  the actor. The tick captures a `Handle` (strong); `Handle` holds
//  the actor (weak). When the actor deinits, the weak reference nils
//  out; the next tick observes `handle.actor == nil` and returns
//  `.halt`.
//
//  This indirection exists because `Polling.init` installs the tick
//  at construction time, forcing a chicken-and-egg with `[weak self]`:
//  `self` cannot be captured (even weakly) until every stored property
//  is initialised, but `self.polling` IS the property being initialised
//  by the expression that contains the tick closure. `Handle` breaks
//  the knot — the closure captures the handle (a local, not `self`),
//  and the handle's `actor` slot is filled at the tail of `init` after
//  `self.polling` has been assigned.
//

// Windows: the event reactor is built on Kernel.Event.Source (epoll/kqueue)
// and Kernel.Thread.Executor.Polling — POSIX-only surfaces (swift-executors
// gates Polling !os(Windows)). Gated whole-file to match the IO Completions
// posture; the Windows leg uses the blocking path per IO+File.System+Default.
#if !os(Windows)
    extension Event.Actor {

        /// Weak cell the tick closure uses to reach the actor without
        /// participating in the retain cycle.
        ///
        /// ## Safety Invariant
        ///
        /// `@unsafe @unchecked Sendable` (Category A per MEM-SAFE-024):
        /// synchronized by the runtime's atomic weak-reference machinery.
        /// `weak var` cannot be `let` (the runtime must zero it on
        /// deallocation). The only write happens at the tail of
        /// `Actor.init`, sequenced-before the Polling thread can observe
        /// any tick; subsequent reads use Swift's atomic weak-ref.
        internal final class Handle: @unsafe @unchecked Sendable {
            weak var actor: Event.Actor?

            init() {}
        }
    }

#endif
