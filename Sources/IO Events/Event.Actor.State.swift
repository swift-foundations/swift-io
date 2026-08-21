#if !os(Windows)
    extension Event.Actor {

        enum State: Sendable {
            case running
            case shuttingDown
        }
    }

#endif
