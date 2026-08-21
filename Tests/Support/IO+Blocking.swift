public import Executors

extension IO where Capabilities == Basic.Capabilities {

    public static func blocking() -> IO<Basic.Capabilities> {
        blocking(on: Basic._sharedBlockingExecutors.next())
    }

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

            }
        )
        let runner = unsafe Self.Runner(
            executor: { unsafe actor.unownedExecutor },
            shutdown: {

            }
        )
        return IO(capabilities: capabilities, runner: runner)
    }
}

extension Basic {

    @usableFromInline
    internal static let _sharedBlockingExecutors: Kernel.Thread.Executor.Sharded = .init()
}
