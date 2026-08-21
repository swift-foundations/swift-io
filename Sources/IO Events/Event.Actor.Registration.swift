#if !os(Windows)
    import Async

    extension Event.Actor {

        struct Registration {
            var senders: Senders = Senders()
        }
    }

#endif
