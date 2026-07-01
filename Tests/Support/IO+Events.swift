//
//  IO+Events.swift
//  swift-io
//
//  Events-strategy factory for the Basic byte-ops domain. Builds an
//  `IO<Basic.Capabilities>` whose capability closures forward to an
//  ``Event/Actor`` and map its strategy-level ``Event/Failure`` onto
//  ``Basic/Error``.
//

public import IO_Events

extension IO where Capabilities == Basic.Capabilities {
    /// Events-strategy I/O for the Basic byte-ops domain, bound to an
    /// explicit ``Event/Actor``.
    ///
    /// Every operation is dispatched through the reactor actor pinned
    /// to its Polling executor. Consumers that forward their own
    /// `unownedExecutor` to the returned bundle (TCA26 shared-executor
    /// pattern) run on the same thread as the reactor — no per-op hop.
    ///
    /// ```swift
    /// let reactor = try Event.Actor()
    /// let io: IO<Basic.Capabilities> = .events(on: reactor)
    /// try await io.ready(from: listener, interest: .read)
    /// ```
    public static func events(on actor: Event.Actor) -> IO<Basic.Capabilities> {
        let capabilities = Basic.Capabilities(
            read: { fd, buf throws(Basic.Error) -> Int in
                do throws(Event.Failure) {
                    return try await actor.read(from: fd, into: buf)
                } catch {
                    throw error.basicError
                }
            },
            write: { fd, buf throws(Basic.Error) -> Int in
                do throws(Event.Failure) {
                    return try await actor.write(to: fd, from: buf)
                } catch {
                    throw error.basicError
                }
            },
            close: { fd in
                await actor.close(consume fd)
            },
            ready: { fd, interest throws(Basic.Error) -> Void in
                do throws(Event.Failure) {
                    try await actor.ready(from: fd, interest: interest)
                } catch {
                    throw error.basicError
                }
            }
        )
        let runner = unsafe IO.Runner(
            executor: { actor.unownedExecutor },
            shutdown: {
                // The actor owns its Polling executor and shuts it down
                // on deinit. No runner action needed.
            }
        )
        return IO(capabilities: capabilities, runner: runner)
    }

    /// Events-strategy I/O bound to the process-shared reactor.
    ///
    /// Convenience wrapper around ``Event/Actor/shared()``. Subsequent
    /// calls return bundles backed by the same reactor so
    /// thread/registration/lifecycle state is shared across them.
    public static func events() throws(Event.Failure) -> IO<Basic.Capabilities> {
        events(on: try Event.Actor.shared())
    }
}
