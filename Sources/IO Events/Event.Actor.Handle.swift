#if !os(Windows)
    extension Event.Actor {

        internal final class Handle: @unsafe @unchecked Sendable {
            weak var actor: Event.Actor?

            init() {}
        }
    }

#endif
