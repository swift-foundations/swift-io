//
//  Event.Actor.Registration.Senders.swift
//  swift-io
//
//  Per-interest sender lists with broadcast-and-drain primitives.
//

import Async

extension Event.Actor.Registration {
    /// Per-interest sender lists. Each list holds the Copyable sender
    /// half of one `Async.Channel.Unbounded` per concurrent awaiter
    /// on that interest direction.
    struct Senders {
        var read: [Async.Channel<Kernel.Event>.Unbounded.Sender] = []
        var write: [Async.Channel<Kernel.Event>.Unbounded.Sender] = []
        var priority: [Async.Channel<Kernel.Event>.Unbounded.Sender] = []
    }
}

// MARK: - Append

extension Event.Actor.Registration.Senders {
    /// Append a sender for the given (single-bit) interest. Priority
    /// is the fallback for unknown bits.
    mutating func append(
        _ sender: Async.Channel<Kernel.Event>.Unbounded.Sender,
        for interest: Kernel.Event.Interest
    ) {
        if interest.contains(.read) {
            read.append(sender)
        } else if interest.contains(.write) {
            write.append(sender)
        } else {
            priority.append(sender)
        }
    }
}

// MARK: - Broadcast and drain

extension Event.Actor.Registration.Senders {
    /// Broadcast a direction-projected event to every sender on the
    /// matching interest list, then drain the list. No-op if the
    /// event does not carry the given interest bit.
    ///
    /// Called from the tick closure inside `assumeIsolated`.
    mutating func drain(
        event: Kernel.Event,
        for interest: Kernel.Event.Interest
    ) {
        guard event.interest.contains(interest) else { return }
        let directed = Kernel.Event(
            id: event.id,
            interest: interest,
            flags: event.flags
        )
        if interest.contains(.read) {
            for sender in read { try? sender.send(directed) }
            read.removeAll()
        } else if interest.contains(.write) {
            for sender in write { try? sender.send(directed) }
            write.removeAll()
        } else {
            for sender in priority { try? sender.send(directed) }
            priority.removeAll()
        }
    }
}

// MARK: - Close

extension Event.Actor.Registration.Senders {
    /// Close every sender across all three interest lists. Any pending
    /// `receive()` observes `nil` and surfaces as
    /// ``IO/Event/Failure/shutdownInProgress``.
    func closeAll() {
        for sender in read { sender.close() }
        for sender in write { sender.close() }
        for sender in priority { sender.close() }
    }
}
