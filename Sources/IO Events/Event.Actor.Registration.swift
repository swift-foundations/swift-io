//
//  Event.Actor.Registration.swift
//  swift-io
//
//  Per-ID dispatch record stored in the Actor's registrations table.
//  Holds a per-interest sender list via the nested `Senders` struct,
//  which implements the broadcast-and-drain primitives used by the
//  actor's dispatch and shutdown paths.
//

import Async

extension Event.Actor {
    /// A registered descriptor with its per-call event senders.
    ///
    /// Each `io.ready` call creates a transient
    /// `Async.Channel.Unbounded` and appends its Copyable sender to
    /// the interest-specific list in ``Senders``. ``dispatch`` invokes
    /// `Senders.drain(event:for:)` for each interest bit; ``cleanup``
    /// invokes `Senders.closeAll()`. The `~Copyable` receiver is held
    /// locally by the awaiter — never shared.
    struct Registration {
        var interest: Kernel.Event.Interest
        var senders: Senders = Senders()
    }
}
