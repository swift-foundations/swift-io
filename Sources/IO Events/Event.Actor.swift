//
//  Event.Actor.swift
//  swift-io
//
//  Public actor backing the events-strategy IO witness. Owns the
//  Kernel.Thread.Executor.Polling directly — no intermediate Loop or
//  wrapper struct. The actor IS the event loop: it holds the executor,
//  the registration table, and the dispatch logic. The tick closure uses
//  `assumeIsolated` to access actor-isolated state (registrations, error
//  policy) from the synchronous polling thread. This works because
//  Polling implements `isIsolatingCurrentContext()` to verify the tick
//  runs on the executor's own thread — the same thread the actor is
//  pinned to.
//
//  Per-call channel dispatch: each `io.ready` call creates a transient
//  `Async.Channel.Unbounded` whose sender is appended to the registration
//  table and whose receiver is local to the awaiter. `dispatch` broadcasts
//  to all senders via `Registration.Senders.drain(event:for:)`; no shared
//  per-fd receiver state, no single-suspender precondition to violate.
//

@_spi(Syscall) import Kernel
import Executors
import Async
import Memory_Primitives

extension Event {

    /// Actor pinned to its own `Kernel.Thread.Executor.Polling` thread.
    /// Serializes driver access (register/arm/deregister), holds the
    /// registration table, and dispatches kernel events to per-call
    /// channel senders.
    ///
    /// ## Safety Invariant
    ///
    /// The actor's `unownedExecutor` returns the Polling executor's
    /// identity. All actor-isolated state is accessed either from actor
    /// methods (dispatched by the runtime to the Polling thread) or from
    /// the tick closure via `assumeIsolated`. In the tick case the runtime
    /// calls Polling's `isIsolatingCurrentContext()` to verify the
    /// calling thread IS the actor's executor thread.
    ///
    /// ## Usage
    ///
    /// ```swift
    /// // Own reactor
    /// let actor = try Event.Actor()
    /// let io = IO.events(on: actor)
    ///
    /// // Or the process-shared reactor
    /// let io = try IO.events()
    /// ```
    ///
    /// ## Intended Use
    ///
    /// - Unified event loop: one OS thread per reactor.
    /// - Actor pinning via `unownedExecutor` — compiler-verified isolation.
    /// - Consumers pin their own actors to this executor for zero-hop I/O.
    public actor Actor {

        /// The polling executor — owns the thread, job queue, and event source.
        ///
        /// `nonisolated let`: single-assignment in init; readable from the
        /// nonisolated `unownedExecutor` accessor without isolation hops.
        /// Polling is `@unchecked Sendable` by construction.
        nonisolated private let polling: Kernel.Thread.Executor.Polling

        /// Lifecycle state.
        fileprivate var state: State = .running

        /// Maps descriptor identity to the driver-assigned registration ID.
        private var registeredIDs: [Event.ID: Event.ID] = [:]

        /// Active registrations for direct event dispatch.
        var registrations: [Event.ID: Registration] = [:]

        /// Creates the actor with the platform event source and its own
        /// OS thread.
        ///
        /// Spawns a dedicated thread running the poll loop. Dropping the
        /// actor shuts down the thread via `deinit`.
        ///
        /// - Parameter maxEventsPerPoll: Maximum number of
        ///   ``Kernel/Event`` records the reactor fetches from the
        ///   platform event source per poll cycle. Sizes the external
        ///   buffer the tick closure receives. Default: 256.
        /// - Throws: ``IO/Event/Failure`` if the platform event source
        ///   fails to initialize.
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

        /// Creates the actor with a caller-supplied event source.
        ///
        /// Inject a custom source — a specific platform backend
        /// (e.g. `Kernel.Event.Source.epoll(maxEvents: 1024)` on Linux)
        /// or a fake source for tests. The default
        /// ``init(maxEventsPerPoll:)`` is equivalent to
        /// `init(source: try .platform(), ...)`.
        ///
        /// - Parameters:
        ///   - source: The event source, consumed by the actor.
        ///   - maxEventsPerPoll: Polling's external buffer size.
        ///     Default: 256.
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
            polling.shutdown()
        }
    }
}

// MARK: - Tick: Outcome init from actor handle + wait thunk

extension Kernel.Thread.Executor.Polling.Outcome {
    /// Compute one tick's outcome for an `Event.Actor`.
    ///
    /// Captured by the executor's `tick` closure to bridge the
    /// synchronous executor-thread context into the actor-isolated
    /// dispatch path. The init takes the actor's weak `Handle`
    /// (avoiding the `[weak self]` init-order trap per [IMPL-083]) and
    /// the executor's `wait` thunk, then materialises the wait result
    /// outside `assumeIsolated` per [IMPL-091] before crossing into
    /// the actor-isolated dispatch body.
    ///
    /// WORKAROUND: Swift 6.3 region-isolation checker rejects capture
    /// of the task-isolated `wait` thunk into an actor-isolated
    /// closure, even though the tick runs on the actor's own executor
    /// thread (verified by `Polling.isIsolatingCurrentContext()`).
    /// Call `wait()` outside `assumeIsolated` and let the events
    /// buffer / typed error cross into the isolated closure via
    /// region transfer — the values sit in a disconnected region and
    /// are never touched after the transfer.
    ///
    /// WHY: region analysis operates on types alone; it does not know
    /// that `isIsolatingCurrentContext()` pins the tick to the
    /// actor's thread at runtime.
    ///
    /// TRACKING: not tracked upstream — this is the canonical shape of
    /// [IMPL-083] on Swift 6.3.
    ///
    /// WHEN TO REMOVE: the consumer-side `assumeIsolated` could be
    /// moved into Polling if Polling were made generic over an actor
    /// type (`Polling<A: Actor>`), with the tick taking `isolated A`.
    /// That eliminates the keyword from consumer code but preserves an
    /// internal `assumeIsolated` in Polling — raw threads have no
    /// static isolation to carry `isolated A`. The region-analysis
    /// rejection on captured `wait` thunks is independent and would
    /// persist.
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

// MARK: - Executor Binding

extension Event.Actor {
    /// Forward to the Polling executor so witness calls run on the
    /// reactor thread via actor isolation.
    nonisolated public var unownedExecutor: UnownedSerialExecutor {
        unsafe polling.asUnownedSerialExecutor()
    }
}

// MARK: - Shared Default

extension Event.Actor {
    /// Process-scoped shared actor.
    ///
    /// Created once on first access; the outcome (success or failure) is
    /// cached for the process lifetime. Under EMFILE / ENOMEM the process
    /// was already at the edge of workable — propagating the original
    /// failure is more useful than flipping between success and failure
    /// across calls. Callers that want fresh retry semantics on their own
    /// schedule can construct ``IO/Event/Actor/init()`` directly.
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

// MARK: - Event Dispatch

extension Event.Actor {

    /// Broadcast kernel events to all per-call channel senders.
    ///
    /// Called from the tick closure on the Polling thread, inside
    /// `assumeIsolated`. The isolation check is satisfied by Polling's
    /// `isIsolatingCurrentContext()` override which verifies the tick
    /// runs on the executor's thread.
    fileprivate func dispatch(_ events: UnsafeBufferPointer<Kernel.Event>) {
        for event in unsafe events {
            guard var registration = registrations[event.id] else { continue }
            registration.senders.drain(event: event, for: .read)
            registration.senders.drain(event: event, for: .write)
            registration.senders.drain(event: event, for: .priority)
            registrations[event.id] = registration
        }
    }

    /// Close every per-call sender across every registration and clear
    /// the dispatch table. Called from the tick closure on fatal wait
    /// failures so awaiters observe shutdown rather than hanging.
    fileprivate func cleanup() {
        for (_, registration) in registrations {
            registration.senders.closeAll()
        }
        registrations.removeAll()
    }
}

// MARK: - Registration

extension Event.Actor {

    /// Ensure the given fd is registered with the driver. Idempotent —
    /// reuses an existing entry.
    ///
    /// A reactor primitive: domains call this, then ``wait(for:interest:)``,
    /// to build readiness-gated operations on top of the reactor.
    public func register(
        _ fd: borrowing Kernel.Descriptor
    ) throws(Event.Failure) -> Event.ID {
        let descriptorID = Kernel.Event.ID(descriptor: fd)
        if let existingID = registeredIDs[descriptorID] {
            return existingID
        }
        guard state == .running else { throw .left(.shutdown) }

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

        registrations[id] = Registration(interest: [.read, .write])
        registeredIDs[descriptorID] = id
        return id
    }

    /// Arm the driver for the given interest.
    private func arm(id: Event.ID, interest: Kernel.Event.Interest) {
        try? polling.source.arm(id: id, interest: interest)
    }

    /// Create a per-call channel, enlist its sender on the matching
    /// interest list, arm the driver, and await readiness.
    ///
    /// A reactor primitive: domains compose this after ``register(_:)``
    /// to build readiness-gated operations.
    public func wait(
        for registrationID: Event.ID,
        interest: Kernel.Event.Interest
    ) async throws(Event.Failure) {
        var channel = Async.Channel<Kernel.Event>.Unbounded()
        registrations[registrationID]?.senders.append(channel.sender, for: interest)

        arm(id: registrationID, interest: interest)

        let ends = (consume channel).take().ends()
        let received: Kernel.Event?
        do {
            received = try await ends.receiver.receive()
        } catch {
            throw Event.Failure.left(.cancelled)
        }

        guard received != nil else {
            throw Event.Failure.left(.shutdown)
        }
    }

    /// Remove the fd's registration, close its per-interest senders,
    /// and deregister from the driver.
    ///
    /// A reactor primitive: domains call this in their own `close(_:)`
    /// wrappers before invoking the kernel's `close(2)`.
    public func deregister(_ descriptorID: Event.ID) {
        guard let registrationID = registeredIDs.removeValue(forKey: descriptorID) else {
            return
        }
        if let registration = registrations.removeValue(forKey: registrationID) {
            registration.senders.closeAll()
        }
        try? polling.source.deregister(id: registrationID)
    }
}
