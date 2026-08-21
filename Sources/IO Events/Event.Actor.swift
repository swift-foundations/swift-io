#if !os(Windows)
    @_spi(Syscall) import Kernel
    import Executors
    import Async
    import Memory_Primitives

    extension Event {

        public actor Actor {

            nonisolated private let polling: Kernel.Thread.Executor.Polling

            var state: State = .running

            private var registeredIDs: [Event.ID: Event.ID] = [:]

            var registrations: [Event.ID: Registration] = [:]

            private var isPollingShutdown = false

            public init(maxEventsPerPoll: Int = 256) throws(Event.Failure) {
                let source: Kernel.Event.Source
                do throws(Kernel.Event.Driver.Error) {
                    source = try Kernel.Event.Source.platform()
                } catch {
                    throw .right(Event.Error(error))
                }
                let handle = Handle()
                self.polling = unsafe Kernel.Thread.Executor.Polling(
                    source: consume source,
                    maxEventsPerPoll: maxEventsPerPoll,
                    tick: { wait in unsafe .init(actorHandle: handle, wait: wait) }
                )
                handle.actor = self
            }

            public init(
                source: consuming Kernel.Event.Source,
                maxEventsPerPoll: Int = 256
            ) {
                let handle = Handle()
                self.polling = unsafe Kernel.Thread.Executor.Polling(
                    source: consume source,
                    maxEventsPerPoll: maxEventsPerPoll,
                    tick: { wait in unsafe .init(actorHandle: handle, wait: wait) }
                )
                handle.actor = self
            }

            deinit {
                if !isPollingShutdown {
                    isPollingShutdown = true
                    polling.shutdown()
                }
            }
        }
    }

    extension Kernel.Thread.Executor.Polling.Outcome {

        init(
            actorHandle: Event.Actor.Handle,
            wait: () throws(Kernel.Event.Driver.Error) -> UnsafeBufferPointer<Kernel.Event>
        ) {
            guard let actor = actorHandle.actor else {
                self = .halt
                return
            }

            do throws(Kernel.Event.Driver.Error) {
                let events = unsafe try wait()
                self = actor.assumeIsolated { isolatedSelf in
                    guard isolatedSelf.state == .running else { return .halt }
                    unsafe isolatedSelf.dispatch(events)
                    return .continue
                }
            } catch {
                self = actor.assumeIsolated { isolatedSelf in
                    guard isolatedSelf.state == .running else { return .halt }
                    switch Event.Actor.RetryDecision(for: error) {
                    case .retry:
                        return .continue

                    case .yieldAndRetry:
                        Kernel.Thread.yield()
                        return .continue

                    case .halt:
                        isolatedSelf.cleanup()
                        return .halt
                    }
                }
            }
        }
    }

    extension Event.Actor {

        nonisolated public var unownedExecutor: UnownedSerialExecutor {
            unsafe polling.asUnownedSerialExecutor()
        }
    }

    extension Event.Actor {

        public static func shared() throws(Event.Failure) -> Event.Actor {
            try _shared.get()
        }

        private static let _shared: Result<Event.Actor, Event.Failure> = {
            do throws(Event.Failure) {
                return .success(try Event.Actor())
            } catch {
                return .failure(error)
            }
        }()
    }

    extension Event.Actor {

        fileprivate func dispatch(_ events: UnsafeBufferPointer<Kernel.Event>) {
            for event in unsafe events {
                guard var registration = registrations[event.id] else { continue }
                registration.senders.drain(event: event, for: .read)
                registration.senders.drain(event: event, for: .write)
                registration.senders.drain(event: event, for: .priority)
                registrations[event.id] = registration
            }
        }

        fileprivate func cleanup() {
            guard state == .running else { return }
            state = .shuttingDown
            for (_, registration) in registrations {
                registration.senders.closeAll()
            }
            registrations.removeAll()
            registeredIDs.removeAll()
        }

        public func shutdown() {
            cleanup()
            guard !isPollingShutdown else { return }
            isPollingShutdown = true
            polling.shutdown()
        }
    }

    extension Event.Actor {

        public func register(
            _ fd: borrowing Kernel.Descriptor
        ) throws(Event.Failure) -> Event.ID {

            guard state == .running else { throw .left(.shutdown) }
            let descriptorID = Kernel.Event.ID(descriptor: fd)
            if let existingID = registeredIDs[descriptorID] {
                return existingID
            }

            let duped: Kernel.Descriptor
            do throws(Kernel.Descriptor.Duplicate.Error) {
                duped = try Kernel.Descriptor.Duplicate.duplicate(fd)
            } catch {
                switch error {
                case .handle: throw .right(.invalidDescriptor)
                case .tooManyOpen: throw .right(.platform(.POSIX.EMFILE))
                case .platform(let e): throw .right(.platform(e.code))
                }
            }

            var descriptorOpt: Kernel.Descriptor? = consume duped
            let id: Event.ID
            do throws(Kernel.Event.Driver.Error) {
                id = try polling.source.register(
                    descriptor: descriptorOpt.take()!,
                    interest: [.read, .write]
                )
            } catch {
                throw .right(Event.Error(error))
            }

            registrations[id] = Registration()
            registeredIDs[descriptorID] = id
            return id
        }

        private func arm(
            id: Event.ID,
            interest: Kernel.Event.Interest
        ) throws(Kernel.Event.Driver.Error) {
            try polling.source.arm(id: id, interest: interest)
        }

        private func remove(
            _ sender: Async.Channel<Kernel.Event>.Unbounded.Sender,
            from registrationID: Event.ID,
            interest: Kernel.Event.Interest
        ) {
            guard var registration = registrations[registrationID] else { return }
            registration.senders.remove(sender, for: interest)
            registrations[registrationID] = registration
        }

        public func wait(
            for registrationID: Event.ID,
            interest: Kernel.Event.Interest
        ) async throws(Event.Failure) {

            guard state == .running else { throw .left(.shutdown) }
            var channel = Async.Channel<Kernel.Event>.Unbounded()
            let sender = channel.sender
            registrations[registrationID]?.senders.append(sender, for: interest)

            do throws(Kernel.Event.Driver.Error) {
                try arm(id: registrationID, interest: interest)
            } catch {
                remove(sender, from: registrationID, interest: interest)
                throw Event.Failure.right(Event.Error(error))
            }

            let ends = (consume channel).take().ends()
            let received: Kernel.Event?
            do {
                received = try await ends.receiver.receive()
            } catch {
                remove(sender, from: registrationID, interest: interest)
                throw Event.Failure.left(.cancelled)
            }

            guard received != nil else {
                throw Event.Failure.left(.shutdown)
            }
        }

        public func deregister(_ descriptorID: Event.ID) {
            guard let registrationID = registeredIDs.removeValue(forKey: descriptorID) else {
                return
            }
            if let registration = registrations.removeValue(forKey: registrationID) {
                registration.senders.closeAll()
            }
            do throws(Kernel.Event.Driver.Error) {
                try polling.source.deregister(id: registrationID)
            } catch {

            }
        }
    }

#endif
