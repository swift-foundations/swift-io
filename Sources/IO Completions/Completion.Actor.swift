//
//  Completion.Actor.swift
//  swift-io
//
//  Public actor backing the completions-strategy IO witness. Owns a
//  `Kernel.Thread.Executor.Completion` directly — no intermediate Loop
//  class, no wrapper struct. The actor IS the proactor runtime: it holds
//  the executor (which in turn owns the Kernel.Completion resource and
//  the OS thread), maintains the in-flight entries table, and dispatches
//  completion events resolved from the kernel back to waiting actor
//  calls. The tick closure uses `assumeIsolated` to reach actor-isolated
//  state from the synchronous executor thread. This works because the
//  Completion executor implements `isIsolatingCurrentContext()` to verify
//  the tick runs on the executor's own thread — the same thread the
//  actor is pinned to.
//
//  Per-call cancellation handshake: each submission carries a
//  `CheckedContinuation` and a shared `Cancellation.Flag`. On task
//  cancellation a second `IORING_OP_ASYNC_CANCEL` submission fires,
//  and the outer `await` does not return until BOTH the original CQE
//  and the cancel CQE have been processed — the buffer-ownership
//  safety invariant of Phase 2C constraint #2.
//

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

        /// Actor pinned to a `Kernel.Thread.Executor.Completion`'s thread.
        ///
        /// Serializes kernel access (submit / cancel) and provides the
        /// witness-shaped public API (`read` / `write` / `close` / `ready`).
        /// Every await runs on the executor thread, so actor methods can
        /// manipulate the entries table and reach the kernel via the
        /// executor's coroutine-scoped `kernel` accessor synchronously.
        ///
        /// ## Safety Invariant
        ///
        /// The actor's `unownedExecutor` returns the Completion executor's
        /// identity. All actor-isolated state is accessed either from actor
        /// methods (dispatched by the runtime to the Completion thread) or
        /// from the tick closure via `assumeIsolated`. In the tick case the
        /// runtime calls Completion's `isIsolatingCurrentContext()` to
        /// verify the calling thread IS the actor's executor thread.
        ///
        /// ## Usage
        ///
        /// ```swift
        /// // Own proactor
        /// let actor = try Completion.Actor()
        /// let io = IO.completions(on: actor)
        ///
        /// // Or the process-shared proactor
        /// let io = try IO.completions()
        /// ```
        ///
        /// ## Intended Use
        ///
        /// - Unified proactor runtime: one OS thread per actor.
        /// - Actor pinning via `unownedExecutor` — compiler-verified isolation.
        /// - Consumers pin their own actors to this executor for zero-hop I/O.
        public actor Actor {

            /// The Completion executor — owns the thread, job queue, and
            /// kernel completion resource.
            ///
            /// `nonisolated let`: single-assignment in init; readable from
            /// the nonisolated `unownedExecutor` accessor without isolation
            /// hops. Completion is `@unsafe @unchecked Sendable` by
            /// construction.
            nonisolated private let completion: Kernel.Thread.Executor.Completion

            /// In-flight entries keyed by operation token (counter-based ID).
            ///
            /// Each in-flight submission owns one entry. On CQE arrival the
            /// dispatch path looks up the token's entry, resolves the outcome,
            /// and resumes the continuation. The column is the sole
            /// correlation and lifetime mechanism — entries (and their dup'd
            /// descriptors) survive until the CQE arrives.
            private var entries: Registry = Registry()

            /// Monotonically-increasing ID counter. Actor isolation
            /// serializes access.
            private var _nextID: UInt64 = 1

            /// Creates the actor with a platform-default proactor.
            ///
            /// Constructs a `Kernel.Completion` via the platform factory
            /// (io_uring on Linux) and hands it to a fresh
            /// `Kernel.Thread.Executor.Completion` which spawns the OS thread
            /// running the proactor run loop.
            ///
            /// - Parameter maxCompletionsPerPoll: Initial capacity of the
            ///   executor's event buffer. Default: 256.
            /// - Throws: ``Kernel/Completion/Error`` if the platform backend
            ///   fails to initialize.
            public init(
                maxCompletionsPerPoll: Int = 256
            ) throws(Kernel.Completion.Error) {
                let kernel: Kernel.Completion = try Kernel.Completion.platform()
                let handle = Handle()
                self.completion = unsafe Kernel.Thread.Executor.Completion(
                    kernel: consume kernel,
                    maxCompletionsPerPoll: maxCompletionsPerPoll,
                    tick: { wait in .init(actorHandle: handle, wait: wait) }
                )
                handle.actor = self
            }

            /// Creates the actor with a caller-supplied kernel completion
            /// resource.
            ///
            /// Inject a custom kernel — a specific platform backend or a
            /// fake for tests. The default ``init(maxCompletionsPerPoll:)``
            /// is equivalent to `init(kernel: try .platform(), …)`.
            ///
            /// - Parameters:
            ///   - kernel: The kernel completion resource, consumed by the
            ///     actor.
            ///   - maxCompletionsPerPoll: Executor event-buffer initial
            ///     capacity. Default: 256.
            public init(
                kernel: consuming Kernel.Completion,
                maxCompletionsPerPoll: Int = 256
            ) {
                let handle = Handle()
                self.completion = Kernel.Thread.Executor.Completion(
                    kernel: consume kernel,
                    maxCompletionsPerPoll: maxCompletionsPerPoll,
                    tick: { wait in .init(actorHandle: handle, wait: wait) }
                )
                handle.actor = self
            }

            deinit {
                completion.shutdown()
            }
        }
    }

    // MARK: - Registry typealias

    extension Completion.Actor {
        /// The in-flight entries column — the move-only ADT-families
        /// Dictionary over the ordered hashed entry column (the
        /// generic-instantiation alias localizes the column choice).
        /// `Completion.Entry` is `~Copyable`, so the move-only column is
        /// the correct ownership shape; the dup'd descriptors live in the
        /// column until the CQE arrives.
        /// `Buffer` is fully qualified to `Buffer_Primitive.Buffer`: this
        /// target imports `Kernel_Completion`, whose `Kernel.Completion.Buffer`
        /// (non-generic) otherwise shadows the generic column buffer.
        private typealias Registry = Dictionary_Primitives.Dictionary<Kernel.Completion.Token, Completion.Entry>
    }

    // MARK: - Tick: Outcome init from actor handle + wait thunk

    extension Kernel.Thread.Executor.Completion.Outcome {
        /// Compute one tick's outcome for an `Completion.Actor`.
        ///
        /// Captured by the executor's `tick` closure to bridge the
        /// synchronous executor-thread context into the actor-isolated
        /// dispatch path. The init takes the actor's weak `Handle`
        /// (avoiding the `[weak self]` init-order trap per [IMPL-083]) and
        /// the executor's `wait` thunk, then materialises the wait result
        /// outside `assumeIsolated` per [IMPL-091] before crossing into
        /// the actor-isolated dispatch body.
        init(
            actorHandle: Completion.Actor.Handle,
            wait: () throws(Kernel.Completion.Error) -> UnsafeBufferPointer<Kernel.Completion.Event>
        ) {
            guard let actor = actorHandle.actor else {
                self = .halt
                return
            }

            // Materialise: call `wait()` outside `assumeIsolated` so
            // the task-isolated thunk does not cross into the actor-
            // isolated closure. The events buffer / typed error cross
            // via region transfer. See [IMPL-091].
            do throws(Kernel.Completion.Error) {
                let events = unsafe try wait()
                self = actor.assumeIsolated { isolatedSelf in
                    unsafe isolatedSelf.dispatch(events)
                    return .continue
                }
            } catch {
                // Transient errors (EINTR, ENOMEM, EAGAIN on flush) are
                // retried on the next iteration. The Kernel.Completion
                // layer does not currently distinguish fatal from
                // transient; match the Phase 1 Loop's retry-always policy
                // until a classification is introduced.
                self = .continue
            }
        }
    }

    // MARK: - Executor Binding

    extension Completion.Actor {
        /// Forward to the Completion executor so witness calls run on its
        /// thread via actor isolation.
        nonisolated public var unownedExecutor: UnownedSerialExecutor {
            unsafe completion.asUnownedSerialExecutor()
        }
    }

    // MARK: - Shared Default

    extension Completion.Actor {
        /// Process-scoped shared actor.
        ///
        /// Created once on first access; the outcome (success or failure)
        /// is cached for the process lifetime. Under EMFILE / ENOMEM or
        /// kernel-unsupported `io_uring` the process was already at the edge
        /// of workable — propagating the original failure is more useful
        /// than flipping between success and failure across calls. Callers
        /// that want fresh retry semantics on their own schedule can
        /// construct ``IO/Completion/Actor/init(maxCompletionsPerPoll:)``
        /// directly.
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

    // MARK: - ID generation

    extension Completion.Actor {

        /// Generate a fresh operation ID. Actor isolation serializes the
        /// counter.
        private func generateID() -> Kernel.Completion.Token {
            let raw = _nextID
            _nextID &+= 1
            return Kernel.Completion.Token(raw)
        }
    }

    // MARK: - CQE dispatch

    extension Completion.Actor {

        /// Dispatch a buffer of kernel completion events to in-flight
        /// entries. Each event's token is the counter-based ID echoed
        /// from the submission. The dictionary lookup IS the correlation
        /// — no retained-pointer recovery needed.
        ///
        /// Cancellation check is integrated: if the matched entry's
        /// cancellation flag is set, the entry is resolved as cancelled
        /// (nil event) rather than with the kernel's result. This replaces
        /// the former `checkCancellations` phase — entries stay in the
        /// dictionary until their CQE arrives, keeping the dup'd descriptor
        /// alive across the kernel's custody window.
        ///
        /// Called from the tick closure on the Completion executor thread,
        /// inside `assumeIsolated`. `fileprivate` so the same-file
        /// `Outcome.init(actorHandle:wait:)` extension can invoke it.
        fileprivate func dispatch(_ events: UnsafeBufferPointer<Kernel.Completion.Event>) {
            for event in unsafe events {
                if let entry = entries.removeValue(forKey: event.token) {
                    if entry.flag.isSet {
                        entry.resolveAsCancelled()
                    } else {
                        entry.resolve(with: event)
                    }
                }
            }
        }

        /// Close every pending entry's continuation and clear the dispatch
        /// table. Used on fatal error paths so awaiters observe
        /// cancellation rather than hanging.
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

    // MARK: - Submission

    extension Completion.Actor {

        /// Submit an entry to the kernel via the Completion executor's
        /// `kernel` accessor, and register it in the entries table.
        ///
        /// Runs on the executor thread (actor-isolated). The executor's
        /// coroutine accessor yields a borrow of `Kernel.Completion`;
        /// submission is a non-consuming borrowing call.
        ///
        /// On submission failure the entry is resolved as cancelled inline
        /// and the error is thrown to the caller.
        private func submit(
            _ entry: consuming Completion.Entry
        ) throws(Kernel.Completion.Error) {
            let id = entry.id
            let submission = Kernel.Completion.Submission(
                opcode: entry.opcode,
                token: id
            )

            var submitError: Kernel.Completion.Error? = nil

            if var descriptor = entry.descriptor.take() {
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

    // MARK: - Submit primitive

    extension Completion.Actor {

        /// Submit a completion opcode, await its CQE, and apply the multi-
        /// CQE cancel handshake on task cancellation.
        ///
        /// This is the domain-agnostic primitive on which each domain
        /// (Basic, File, Socket, Server) builds its own operations. Each
        /// call mints a fresh token internally, submits the SQE, awaits the
        /// CQE, and invokes `mapEvent` to interpret the kernel's result.
        ///
        /// ## Handshake semantics (supervisor constraint #2)
        ///
        /// 1. Submit the original SQE + await its CQE via
        ///    `withCheckedContinuation`. The continuation carries the
        ///    kernel event directly (`Event?`); `nil` means cancelled.
        /// 2. On task cancellation, the outer `onCancel` handler claims the
        ///    cancel slot (`CancelCoordinator.tryBegin`) and spawns a
        ///    detached task that submits `IORING_OP_ASYNC_CANCEL`, awaits
        ///    its CQE, and opens the coordinator's gate.
        /// 3. After stage 1's continuation resumes (when the CQE arrives),
        ///    if a cancel was claimed, stage 2 awaits the coordinator's
        ///    gate — ensuring the outer `await io.*` does NOT return until
        ///    both CQEs have been processed (buffer-ownership safety).
        ///
        /// - Parameters:
        ///   - opcode: The opcode to submit. Domains pass their own
        ///     (`.read`, `.write`, `.readiness`, future `.open`,
        ///     `.metadata`, …) — platform-neutral names, not syscall
        ///     names.
        ///   - descriptor: A descriptor to keep alive for the kernel's
        ///     custody window. Pass a dup'd descriptor for fd-carrying
        ///     ops; `nil` for ops that don't target an fd.
        ///   - mapEvent: How to interpret the CQE into the caller's
        ///     result type (and throw the caller's typed error).
        public func submit<R>(
            _ opcode: Kernel.Completion.Submission.Opcode,
            descriptor: consuming Kernel.Descriptor? = nil,
            mapEvent: (Kernel.Completion.Event) throws(Completion.Failure) -> R
        ) async throws(Completion.Failure) -> R {
            let id = generateID()
            let flag = Completion.Cancellation()
            let coord = CancelCoordinator()

            let event: Kernel.Completion.Event? = await withTaskCancellationHandler {
                // Stage 1: submit original + await original CQE.
                let result: Kernel.Completion.Event? = await withCheckedContinuation {
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
                        // `submit` already called
                        // `entry.resolveAsCancelled()` on failure, which
                        // resumed the continuation.
                    }
                }

                // Stage 2: if a cancel was submitted, wait for the cancel CQE too.
                if coord.isCancelled {
                    await coord.waitForCancelCQE()
                }

                return result
            } onCancel: {
                // Exactly-once gate: the first onCancel firing wins.
                if coord.tryBegin() {
                    flag.set()
                    // Actor-hop required — cancel submission needs the
                    // executor-thread-confined submit path.
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

        /// Submit an `IORING_OP_ASYNC_CANCEL` for `targetID` and await its
        /// CQE. Invoked from the `Task { }` launched by the outer
        /// `onCancel` handler.
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
                    // Already resolved as cancelled by submit.
                }
            }
            coord.markCancelCQEReceived()
        }
    }

    // MARK: - Cancel coordinator

    extension Completion.Actor {

        /// Coordinates the two-CQE cancel handshake.
        ///
        /// Single-writer claim (`tryBegin`) + one-shot gate
        /// (`waitForCancelCQE` / `markCancelCQEReceived`). Reference-typed
        /// because `onCancel` closures are `@Sendable` and cannot capture
        /// actor-isolated or inout value types.
        ///
        /// ## Safety Invariant
        ///
        /// All mutable state (`_cancelled`, `_gateOpened`,
        /// `_gateContinuation`) is guarded by an internal
        /// `Synchronizer.Blocking<1>`. Every access goes through
        /// `sync.synchronize`, providing mutual exclusion across the actor job
        /// and the executor-thread CQE dispatch.
        fileprivate final class CancelCoordinator: @unsafe @unchecked Sendable {
            private let sync: Synchronizer.Blocking<1> = .init()
            private var _cancelled: Bool = false
            private var _gateOpened: Bool = false
            private var _gateContinuation: CheckedContinuation<Void, Never>?

            /// Claim the cancel slot. Returns `true` on the first call only.
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

            /// Suspend until `markCancelCQEReceived()` is called.
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

            /// Open the gate. Any subsequent `waitForCancelCQE()` returns
            /// immediately; a concurrent in-flight wait is resumed now.
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
