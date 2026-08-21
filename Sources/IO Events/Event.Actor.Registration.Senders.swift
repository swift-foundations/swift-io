#if !os(Windows)
    import Async

    extension Event.Actor.Registration {

        struct Senders {
            var read: [Async.Channel<Kernel.Event>.Unbounded.Sender] = []
            var write: [Async.Channel<Kernel.Event>.Unbounded.Sender] = []
            var priority: [Async.Channel<Kernel.Event>.Unbounded.Sender] = []
        }
    }

    extension Event.Actor.Registration.Senders {

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

    extension Event.Actor.Registration.Senders {

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

    extension Event.Actor.Registration.Senders {

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

                    }
                }
            } else if interest.contains(.write) {
                let senders = write
                write.removeAll()
                for sender in senders {
                    do throws(Async.Channel<Kernel.Event>.Error) {
                        try sender.send(directed)
                    } catch {

                    }
                }
            } else {
                let senders = priority
                priority.removeAll()
                for sender in senders {
                    do throws(Async.Channel<Kernel.Event>.Error) {
                        try sender.send(directed)
                    } catch {

                    }
                }
            }
        }
    }

    extension Event.Actor.Registration.Senders {

        func closeAll() {
            for sender in read { sender.close() }
            for sender in write { sender.close() }
            for sender in priority { sender.close() }
        }
    }

#endif
