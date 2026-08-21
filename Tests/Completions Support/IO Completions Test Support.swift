#if !os(Windows)

    @_spi(Syscall) public import Kernel_Completion
    public import IO_Test_Support
    public import IO_Events
    import Synchronizer_Blocking

    extension IO where Capabilities == Basic.Capabilities {

        public static func completionsTest() throws -> IO<Basic.Capabilities> {
            #if os(Linux)
                if Kernel.IO.Uring.isSupported {
                    return try Self.completions()
                }
                return try Self.events()
            #else
                return try Self.events()
            #endif
        }
    }

    extension Kernel.Completion {

        public final class Fake: @unchecked Sendable {

            private let sync: Synchronizer.Blocking<1> = .init()

            private var _submissions: [Kernel.Completion.Submission] = []
            private var _completions: [Kernel.Completion.Event] = []
            private var _flushCount: Int = 0
            private var _isClosed: Bool = false
            private var _onSubmit:
                (@Sendable (Kernel.Completion.Submission) -> Kernel.Completion.Event?)? = nil
            private var _response:
                (@Sendable (Kernel.Completion.Submission) -> [Kernel.Completion.Event])? = nil
            private var _started: Bool = true

            public init() {}
        }
    }

    extension Kernel.Completion.Fake {

        public func holdUntilStarted() {
            sync.synchronize { _started = false }
        }

        public func start() {
            sync.synchronize { _started = true }
            sync.broadcast()
        }

        public var onSubmit: (@Sendable (Kernel.Completion.Submission) -> Kernel.Completion.Event?)?
        {
            get { sync.synchronize { _onSubmit } }
            set { sync.synchronize { _onSubmit = newValue } }
        }

        public var response:
            (@Sendable (Kernel.Completion.Submission) -> [Kernel.Completion.Event])?
        {
            get { sync.synchronize { _response } }
            set { sync.synchronize { _response = newValue } }
        }

        public var submissions: [Kernel.Completion.Submission] {
            sync.synchronize { _submissions }
        }

        public var flushCount: Int {
            sync.synchronize { _flushCount }
        }

        public var isClosed: Bool {
            sync.synchronize { _isClosed }
        }

        public func wait(
            for count: Int,
            timeout: Duration = .seconds(5)
        ) -> Bool {
            let deadline = ContinuousClock.now.advanced(by: timeout)
            sync.lock()
            defer { sync.unlock() }
            while _submissions.count < count {
                let remaining = ContinuousClock.now.duration(to: deadline)
                guard remaining > .zero else { return false }
                _ = sync.wait(condition: 0, timeout: remaining)
            }
            return true
        }

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

        func recordSubmission(_ submission: Kernel.Completion.Submission) {
            sync.synchronize {
                _submissions.append(submission)
                if let respond = _response {
                    _completions.append(contentsOf: respond(submission))
                } else if let respond = _onSubmit, let event = respond(submission) {
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

    extension Kernel.Completion {

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

    extension Completion.Actor {

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
