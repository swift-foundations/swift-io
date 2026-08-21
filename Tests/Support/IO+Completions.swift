#if !os(Windows)

    public import IO_Completions
    public import Kernel_Completion

    extension IO where Capabilities == Basic.Capabilities {

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
                ready: { fd, interest throws(Basic.Error) in
                    do throws(Completion.Failure) {
                        try await actor.ready(from: fd, interest: interest)
                    } catch {
                        throw error.basicError
                    }
                }
            )
            let runner = unsafe Self.Runner(
                executor: { actor.unownedExecutor },
                shutdown: {

                }
            )
            return IO(capabilities: capabilities, runner: runner)
        }

        public static func completions() throws(Kernel.Completion.Error) -> IO<Basic.Capabilities> {
            completions(on: try Completion.Actor.shared())
        }
    }

#endif
