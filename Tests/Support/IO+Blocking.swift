//
//  IO+Blocking.swift
//  swift-io
//
//  Blocking strategy factory for the Basic byte-ops domain. Builds an
//  `IO<Basic.Capabilities>` whose capability closures forward to a
//  `Kernel.Thread.Actor` pinned to a concrete `Kernel.Thread.Executor`.
//  Actor isolation guarantees every syscall runs on that executor's
//  dedicated OS thread — `Task.sleep`, `@MainActor` hops, and
//  unstructured tasks all preserve the binding.
//

public import Executors

extension IO where Capabilities == Basic.Capabilities {

    /// Blocking thread-pool I/O for the Basic byte-ops domain.
    ///
    /// Rotates through a process-scoped sharded executor pool, pinning
    /// one `Kernel.Thread.Actor` per call. Pass an explicit executor
    /// via ``blocking(on:)`` to share threads across multiple
    /// `IO<Basic.Capabilities>` values.
    ///
    /// ```swift
    /// let io: IO<Basic.Capabilities> = .blocking()
    /// let n = try await io.read(from: fd, into: buf)
    /// ```
    ///
    /// ## Executor Binding
    ///
    /// Actor isolation guarantees every call runs on the pinned
    /// `Kernel.Thread.Executor`. `Task.sleep(...)`, `@MainActor` hops,
    /// and unstructured `Task { }` children cannot break the binding.
    public static func blocking() -> IO<Basic.Capabilities> {
        blocking(on: Basic._sharedBlockingExecutors.next())
    }

    /// Blocking I/O strategy bound to an explicit executor.
    ///
    /// Use this overload to co-locate an application actor with the
    /// `IO` on a single executor thread — the runtime elides the per-op
    /// hop when the consumer actor forwards `unownedExecutor`:
    ///
    /// ```swift
    /// actor Server {
    ///     let executor = Kernel.Thread.Executor()
    ///     let io: IO<Basic.Capabilities>
    ///     init() { self.io = .blocking(on: executor) }
    ///     nonisolated var unownedExecutor: UnownedSerialExecutor {
    ///         io.unownedExecutor
    ///     }
    /// }
    /// ```
    ///
    /// The caller owns the executor and is responsible for its
    /// shutdown (when applicable). The factory does not shut it down.
    public static func blocking(on executor: Kernel.Thread.Executor) -> IO<Basic.Capabilities> {
        let actor = Kernel.Thread.Actor(executor: executor)
        let capabilities = Basic.Capabilities(
            read: { fd, buf throws(Basic.Error) -> Int in
                try await actor.read(from: fd, into: buf)
            },
            write: { fd, buf throws(Basic.Error) -> Int in
                try await actor.write(to: fd, from: buf)
            },
            close: { fd in
                await actor.close(consume fd)
            },
            ready: { _, _ throws(Basic.Error) in
                // Blocking strategy treats all fds as always ready — the
                // subsequent syscall is the actual block. Ready-then-
                // syscall composes correctly across strategies with this
                // no-op.
            }
        )
        let runner = unsafe Self.Runner(
            executor: { unsafe actor.unownedExecutor },
            shutdown: {
                // The caller owns the supplied executor's lifecycle
                // (or this executor came from the process-scoped
                // shared pool); the factory does not shut it down.
            }
        )
        return IO(capabilities: capabilities, runner: runner)
    }
}

// MARK: - Shared blocking executors

extension Basic {

    /// Process-scoped sharded executor pool for the default blocking
    /// factory. Lazily initialized; lives for the process lifetime.
    ///
    /// Each call to ``IO/blocking()`` pins one shard (via
    /// ``Kernel/Thread/Executor/Sharded/next()``) to a fresh
    /// `Kernel.Thread.Actor`.
    @usableFromInline
    internal static let _sharedBlockingExecutors: Kernel.Thread.Executor.Sharded = .init()
}
