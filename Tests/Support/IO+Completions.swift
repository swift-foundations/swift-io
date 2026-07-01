//
//  IO+Completions.swift
//  swift-io
//
//  Completions-strategy factory for the Basic byte-ops domain. Builds
//  an `IO<Basic.Capabilities>` whose capability closures forward to a
//  ``Completion/Actor`` and map its strategy-level
//  ``Completion/Failure`` onto ``Basic/Error``.
//
//  The factory is declared on every POSIX platform; only Linux has a
//  working `Kernel.Completion.platform()`. On Darwin the shared actor
//  constructor throws `.unsupportedPlatform`, which the host-adaptive
//  selector catches via `try?` and falls through to the reactor.
//  Windows (IOCP) is a future phase — the symbol is absent there.
//

#if !os(Windows)

public import IO_Completions
public import Kernel_Completion

extension IO where Capabilities == Basic.Capabilities {
    /// Completions-strategy I/O for the Basic byte-ops domain, bound
    /// to an explicit ``Completion/Actor``.
    ///
    /// Every operation is dispatched through the proactor actor pinned
    /// to its Completion executor thread. Consumers that forward their
    /// own `unownedExecutor` to the returned bundle (TCA26 shared-
    /// executor pattern) run on the same thread as the proactor —
    /// no per-op hop.
    ///
    /// ## Buffer Ownership
    ///
    /// `read` / `write` pass the buffer as a non-owning pointer view.
    /// The caller MUST keep the pointed-to memory at a stable address
    /// for the duration of the enclosing `try await` expression. On
    /// task cancellation the actor submits `IORING_OP_ASYNC_CANCEL`
    /// and awaits BOTH the original CQE and the cancel CQE before
    /// unwinding.
    ///
    /// ```swift
    /// let proactor = try Completion.Actor()
    /// let io: IO<Basic.Capabilities> = .completions(on: proactor)
    /// ```
    public static func completions(on actor: Completion.Actor) -> IO<Basic.Capabilities> {
        let capabilities = Basic.Capabilities(
            read: { fd, buf throws(Basic.Error) -> Int in
                do throws(Completion.Failure) {
                    return try await actor.read(from: fd, into: buf)
                } catch {
                    throw error.basicError
                }
            },
            write: { fd, buf throws(Basic.Error) -> Int in
                do throws(Completion.Failure) {
                    return try await actor.write(to: fd, from: buf)
                } catch {
                    throw error.basicError
                }
            },
            close: { fd in
                await actor.close(consume fd)
            },
            ready: { fd, interest throws(Basic.Error) -> Void in
                do throws(Completion.Failure) {
                    try await actor.ready(from: fd, interest: interest)
                } catch {
                    throw error.basicError
                }
            }
        )
        let runner = unsafe IO.Runner(
            executor: { actor.unownedExecutor },
            shutdown: {
                // The actor owns its Completion executor and shuts it
                // down on deinit. No runner action needed.
            }
        )
        return IO(capabilities: capabilities, runner: runner)
    }

    /// Completions-strategy I/O bound to the process-shared proactor.
    ///
    /// Convenience wrapper around ``Completion/Actor/shared()``.
    /// Subsequent calls return bundles backed by the same actor so
    /// thread / submission / lifecycle state is shared across them.
    public static func completions() throws(Kernel.Completion.Error) -> IO<Basic.Capabilities> {
        completions(on: try Completion.Actor.shared())
    }
}

#endif
