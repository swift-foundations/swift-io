//
//  IO Completions Test Support.swift
//  swift-io
//
//  Cross-platform test factory + in-memory fake backend for the IO
//  Completions subsystem.
//

#if !os(Windows)

    @_spi(Syscall) public import Kernel_Completion
    public import IO_Test_Support
    public import IO_Events
    import Synchronizer_Blocking

    // MARK: - Cross-Platform IO Witness Factory

    extension IO where Capabilities == Basic.Capabilities {
        /// Cross-platform completions test witness.
        ///
        /// On Linux: `IO.completions()` (real io_uring).
        /// On macOS/Darwin: `IO.events()` (kqueue).
        ///
        /// Tests using this factory exercise the same IO contract on both
        /// platforms, backed by the best available engine.
        public static func completionsTest() throws -> IO<Basic.Capabilities> {
            #if os(Linux)
                return try Self.completions()
            #else
                return try Self.events()
            #endif
        }
    }

    // MARK: - Kernel.Completion.Fake

    extension Kernel.Completion {

        /// In-memory fake for deterministic testing.
        ///
        /// Records submissions and auto-generates completion events via
        /// ``onSubmit``. Thread-safe: test-thread setters and executor-
        /// thread driver closures synchronize through an internal mutex.
        ///
        /// Per [TEST-022] Category 3: reusable coordination infrastructure
        /// for complex test scenarios.
        public final class Fake: @unchecked Sendable {

            private let sync: Synchronizer.Blocking<1> = .init()

            private var _submissions: [Kernel.Completion.Submission] = []
            private var _completions: [Kernel.Completion.Event] = []
            private var _flushCount: Int = 0
            private var _isClosed: Bool = false
            private var _onSubmit: (@Sendable (Kernel.Completion.Submission) -> Kernel.Completion.Event?)? = nil
            private var _started: Bool = true

            public init() {}
        }
    }

    extension Kernel.Completion.Fake {

        // MARK: - Startup Gate

        /// Close the gate. The executor thread blocks on drain until
        /// ``start()`` is called. Used by ``IO/Completion/Actor/fake()``
        /// to ensure `handle.actor = self` completes before the first
        /// tick fires.
        public func holdUntilStarted() {
            sync.synchronize { _started = false }
        }

        /// Open the gate. Wakes the blocked executor thread.
        public func start() {
            sync.synchronize { _started = true }
            sync.broadcast()
        }

        // MARK: - Auto-Responder

        /// Auto-generate a CQE when a submission arrives.
        ///
        /// Called synchronously inside the driver's `submit()` under
        /// the lock. Non-nil return enqueues the event for the next
        /// drain (same tick cycle). Nil leaves the operation pending.
        public var onSubmit: (@Sendable (Kernel.Completion.Submission) -> Kernel.Completion.Event?)? {
            get { sync.synchronize { _onSubmit } }
            set { sync.synchronize { _onSubmit = newValue } }
        }

        // MARK: - Observables

        /// All submissions recorded.
        public var submissions: [Kernel.Completion.Submission] {
            sync.synchronize { _submissions }
        }

        /// Number of `flush()` calls.
        public var flushCount: Int {
            sync.synchronize { _flushCount }
        }

        /// Whether `close()` has been called.
        public var isClosed: Bool {
            sync.synchronize { _isClosed }
        }

        /// Block until `close()` has been called on the driver.
        public func waitUntilClosed(
            timeout: Duration = .seconds(5)
        ) -> Bool {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            sync.lock()
            defer { sync.unlock() }
            while !_isClosed {
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { return false }
                _ = sync.wait(condition: 0, timeout: remaining)
            }
            return true
        }

        // MARK: - Driver-Facing

        func recordSubmission(_ submission: Kernel.Completion.Submission) {
            sync.synchronize {
                _submissions.append(submission)
                if let respond = _onSubmit, let event = respond(submission) {
                    _completions.append(event)
                }
            }
            sync.broadcast()
        }

        func drainCompletions(
            _ visit: (Kernel.Completion.Event) -> Void
        ) -> Kernel.Completion.Event.Count {
            sync.lock()
            while !_started && !_isClosed {
                sync.wait(condition: 0)
            }
            let events = _completions
            _completions.removeAll()
            sync.unlock()

            var count: Kernel.Completion.Event.Count = .zero
            for event in events {
                visit(event)
                count += .one
            }
            return count
        }

        func recordFlush() -> Kernel.Completion.Submission.Count {
            sync.synchronize { _flushCount += 1 }
            return .zero
        }

        func recordClose() {
            sync.synchronize {
                _isClosed = true
            }
            sync.broadcast()
        }

        func recordWakeup() {}
    }

    // MARK: - Kernel.Completion.fake(backend:)

    extension Kernel.Completion {

        /// Build a `Kernel.Completion` wired to an in-memory fake.
        public static func fake(_ backend: Fake) -> Self {
            let driver = Self.Driver(
                submit: { submission, _ in
                    backend.recordSubmission(submission)
                },
                flush: {
                    backend.recordFlush()
                },
                drain: { visit in
                    backend.drainCompletions(visit)
                },
                close: {
                    backend.recordClose()
                }
            )
            let wakeup = Kernel.Wakeup.Channel(signal: { backend.recordWakeup() })
            return Kernel.Completion(
                driver: consume driver,
                wakeup: wakeup,
                notification: nil,
                capabilities: .init()
            )
        }
    }

    // MARK: - Completion.Actor.fake()

    extension Completion.Actor {

        /// Create a fake-backed actor and its backend in one call.
        public static func fake(
            maxCompletionsPerPoll: Int = 256
        ) -> (Completion.Actor, Kernel.Completion.Fake) {
            let backend = Kernel.Completion.Fake()
            backend.holdUntilStarted()
            let actor = Completion.Actor(
                kernel: Kernel.Completion.fake(backend),
                maxCompletionsPerPoll: maxCompletionsPerPoll
            )
            backend.start()
            return (actor, backend)
        }
    }

#endif
