//
//  Event.Actor.Registration.Senders.swift
//  swift-io
//
//  Per-interest sender lists with broadcast-and-drain primitives.
//

// Windows: the event reactor is built on Kernel.Event.Source (epoll/kqueue)
// and Kernel.Thread.Executor.Polling — POSIX-only surfaces (swift-executors
// gates Polling !os(Windows)). Gated whole-file to match the IO Completions
// posture; the Windows leg uses the blocking path per IO+File.System+Default.
#if !os(Windows)
    import Async

    extension Event.Actor.Registration {
        /// Per-interest sender lists. Each list holds the Copyable sender
        /// half of one `Async.Channel.Unbounded` per concurrent awaiter.
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

    // MARK: - Remove

    extension Event.Actor.Registration.Senders {
        /// Remove and close one exact sender endpoint. A repeated removal is a no-op,
        /// which makes cancellation safe when dispatch or shutdown won the
        /// race and already drained the matching list.
        mutating func remove(
            _ sender: Async.Channel<Kernel.Event>.Unbounded.Sender,
            for interest: Kernel.Event.Interest
        ) {
            if interest.contains(.read) {
                if let index = read.firstIndex(of: sender) {
                    read.remove(at: index).close()
                }
            } else if interest.contains(.write) {
                if let index = write.firstIndex(of: sender) {
                    write.remove(at: index).close()
                }
            } else {
                if let index = priority.firstIndex(of: sender) {
                    priority.remove(at: index).close()
                }
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
                let senders = read
                read.removeAll()
                for sender in senders {
                    do throws(Async.Channel<Kernel.Event>.Error) {
                        try sender.send(directed)
                    } catch {
                        // Best-effort broadcast: a closed receiver is dropped
                        // silently; other senders on this list still get delivery.
                    }
                }
            } else if interest.contains(.write) {
                let senders = write
                write.removeAll()
                for sender in senders {
                    do throws(Async.Channel<Kernel.Event>.Error) {
                        try sender.send(directed)
                    } catch {
                        // Best-effort broadcast: a closed receiver is dropped
                        // silently; other senders on this list still get delivery.
                    }
                }
            } else {
                let senders = priority
                priority.removeAll()
                for sender in senders {
                    do throws(Async.Channel<Kernel.Event>.Error) {
                        try sender.send(directed)
                    } catch {
                        // Best-effort broadcast: a closed receiver is dropped
                        // silently; other senders on this list still get delivery.
                    }
                }
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

#endif
