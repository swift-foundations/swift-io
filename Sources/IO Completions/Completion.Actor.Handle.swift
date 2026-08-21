#if !os(Windows)

    extension Completion.Actor {

        internal final class Handle: @unsafe @unchecked Sendable {
            weak var actor: Completion.Actor?

            init() {}
        }
    }

#endif
