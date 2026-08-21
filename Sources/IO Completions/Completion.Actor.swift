#if !os(Windows)

    import Kernel_Completion
    import Executors
    import Synchronizer_Blocking
    import Memory_Primitives
    import Dictionary_Primitives
    import Hash_Indexed_Primitive
    import Hash_Tagged_Primitives
    import Buffer_Primitive
    import Buffer_Linear_Primitive
    import Buffer_Linear_Primitives
    import Storage_Primitive
    import Storage_Contiguous_Primitives
    import Memory_Heap_Primitives
    import Memory_Allocator_Primitive

    extension Completion {

        public actor Actor {

            nonisolated private let completion: Kernel.Thread.Executor.Completion

            private var entries: Registry = Registry()

            private var _nextID: UInt64 = 1

            public init(
                maxCompletionsPerPoll: Int = 256
            ) throws(Kernel.Completion.Error) {
                let kernel: Kernel.Completion = try Kernel.Completion.platform()
                let handle = Handle()
                self.completion = unsafe Kernel.Thread.Executor.Completion(
                    kernel: consume kernel,
                    maxCompletionsPerPoll: maxCompletionsPerPoll,
                    tick: { wait in unsafe .init(actorHandle: handle, wait: wait) }
                )
                handle.actor = self
            }

            public init(
                kernel: consuming Kernel.Completion,
                maxCompletionsPerPoll: Int = 256
            ) {
                let handle = Handle()
                self.completion = unsafe Kernel.Thread.Executor.Completion(
                    kernel: consume kernel,
                    maxCompletionsPerPoll: maxCompletionsPerPoll,
                    tick: { wait in unsafe .init(actorHandle: handle, wait: wait) }
                )
                handle.actor = self
            }

            deinit {
                completion.shutdown()
            }
        }
    }

    extension Completion.Actor {

        private typealias Registry = Dictionary_Primitives.Dictionary<
            Kernel.Completion.Token, Completion.Entry
        >
    }

    extension Kernel.Thread.Executor.Completion.Outcome {

        init(
            actorHandle: Completion.Actor.Handle,
            wait: () throws(Kernel.Completion.Error) -> UnsafeBufferPointer<Kernel.Completion.Event>
        ) {
            guard let actor = actorHandle.actor else {
                self = .halt
                return
            }

            do throws(Kernel.Completion.Error) {
                let events = unsafe try wait()
                self = actor.assumeIsolated { isolatedSelf in
                    unsafe isolatedSelf.dispatch(events)
                    return .continue
                }
            } catch {

                self = .continue
            }
        }
    }

    extension Completion.Actor {

        nonisolated public var unownedExecutor: UnownedSerialExecutor {
            unsafe completion.asUnownedSerialExecutor()
        }
    }

    extension Completion.Actor {

        public static func shared() throws(Kernel.Completion.Error) -> Completion.Actor {
            try _shared.get()
        }

        private static let _shared: Result<Completion.Actor, Kernel.Completion.Error> = {
            do throws(Kernel.Completion.Error) {
                return .success(try Completion.Actor())
            } catch {
                return .failure(error)
            }
        }()
    }

    extension Completion.Actor {

        private func generateID() -> Kernel.Completion.Token {
            let raw = _nextID
            _nextID &+= 1
            return Kernel.Completion.Token(raw)
        }
    }

    extension Completion.Actor {

        fileprivate func dispatch(_ events: UnsafeBufferPointer<Kernel.Completion.Event>) {
            for unsafe event in unsafe events {
                if let entry = entries.removeValue(forKey: event.token) {
                    if entry.flag.isSet {
                        entry.resolveAsCancelled()
                    } else {
                        entry.resolve(with: event)
                    }
                }
            }
        }

        private func cleanup() {
            var remainingIDs: [Kernel.Completion.Token] = []
            entries.forEach { id, _ in
                remainingIDs.append(id)
            }
            for id in remainingIDs {
                if let entry = entries.removeValue(forKey: id) {
                    entry.resolveAsCancelled()
                }
            }
        }
    }

    extension Completion.Actor {

        private func submit(
            _ entry: consuming Completion.Entry
        ) throws(Kernel.Completion.Error) {
            let id = entry.id
            let submission = Kernel.Completion.Submission(
                opcode: entry.opcode,
                token: id
            )

            var submitError: Kernel.Completion.Error? = nil

            if let descriptor = entry.descriptor.take() {
                do throws(Kernel.Completion.Error) {
                    try completion.kernel.submit(submission, target: descriptor)
                } catch let e {
                    submitError = e
                }
                entry.descriptor = consume descriptor
            } else {
                do throws(Kernel.Completion.Error) {
                    try completion.kernel.submit(submission)
                } catch let e {
                    submitError = e
                }
            }

            if let err = submitError {
                entry.resolveAsCancelled()
                throw err
            }

            entries.insert(key: id, value: consume entry)
        }
    }

    extension Completion.Actor {

        public func submit<R>(
            _ opcode: Kernel.Completion.Submission.Opcode,
            descriptor: consuming Kernel.Descriptor? = nil,
            mapEvent: (Kernel.Completion.Event) throws(Completion.Failure) -> R
        ) async throws(Completion.Failure) -> R {
            let id = generateID()
            let flag = Completion.Cancellation()
            let coord = CancelCoordinator()

            let event: Kernel.Completion.Event? = await withTaskCancellationHandler {

                let result: Kernel.Completion.Event? = await awaitEvent(
                    id: id,
                    opcode: opcode,
                    descriptor: consume descriptor,
                    flag: flag
                )
                descriptor = nil

                if coord.isCancelled {
                    await coord.waitForCancelCQE()
                }

                return result
            } onCancel: {

                if coord.tryBegin() {
                    flag.set()

                    Task { [weak self] in
                        guard let self else { return }
                        await submitAsyncCancel(targetID: id, coord: coord)
                    }
                }
            }

            guard let event else {
                throw .cancelled
            }
            return try mapEvent(event)
        }

        private func awaitEvent(
            id: Kernel.Completion.Token,
            opcode: Kernel.Completion.Submission.Opcode,
            descriptor: consuming Kernel.Descriptor?,
            flag: Completion.Cancellation
        ) async -> Kernel.Completion.Event? {
            await withCheckedContinuation {
                (c: CheckedContinuation<Kernel.Completion.Event?, Never>) in
                let entry = Completion.Entry(
                    id: id,
                    opcode: opcode,
                    descriptor: consume descriptor,
                    flag: flag,
                    continuation: c
                )
                descriptor = nil
                do throws(Kernel.Completion.Error) {
                    try self.submit(consume entry)
                } catch {

                }
            }
        }

        private func submitAsyncCancel(
            targetID: Kernel.Completion.Token,
            coord: CancelCoordinator
        ) async {
            let cancelID = generateID()
            let cancelFlag = Completion.Cancellation()

            let _: Kernel.Completion.Event? = await withCheckedContinuation {
                (c: CheckedContinuation<Kernel.Completion.Event?, Never>) in
                let cancelEntry = Completion.Entry(
                    id: cancelID,
                    opcode: .cancel(target: targetID),
                    descriptor: nil,
                    flag: cancelFlag,
                    continuation: c
                )
                do throws(Kernel.Completion.Error) {
                    try self.submit(consume cancelEntry)
                } catch {

                }
            }
            coord.markCancelCQEReceived()
        }
    }

    extension Completion.Actor {

        fileprivate final class CancelCoordinator: @unsafe @unchecked Sendable {
            private let sync: Synchronizer.Blocking<1> = .init()
            private var _cancelled: Bool = false
            private var _gateOpened: Bool = false
            private var _gateContinuation: CheckedContinuation<Void, Never>?

            fileprivate func tryBegin() -> Bool {
                sync.synchronize {
                    if _cancelled { return false }
                    _cancelled = true
                    return true
                }
            }

            fileprivate var isCancelled: Bool {
                sync.synchronize { _cancelled }
            }

            fileprivate func waitForCancelCQE() async {
                await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
                    let resumeImmediately: Bool = sync.synchronize {
                        if _gateOpened { return true }
                        _gateContinuation = c
                        return false
                    }
                    if resumeImmediately {
                        c.resume()
                    }
                }
            }

            fileprivate func markCancelCQEReceived() {
                let pending: CheckedContinuation<Void, Never>? = sync.synchronize {
                    _gateOpened = true
                    let c = _gateContinuation
                    _gateContinuation = nil
                    return c
                }
                pending?.resume()
            }
        }
    }

#endif
