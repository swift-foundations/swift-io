#if !os(Windows)

    public import IO_Events

    extension IO where Capabilities == Basic.Capabilities {

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
                ready: { fd, interest throws(Basic.Error) in
                    do throws(Event.Failure) {
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

        public static func events() throws(Event.Failure) -> IO<Basic.Capabilities> {
            events(on: try Event.Actor.shared())
        }
    }

#endif
