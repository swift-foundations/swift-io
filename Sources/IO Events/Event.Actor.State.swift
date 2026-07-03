//
//  Event.Actor.State.swift
//  swift-io
//

// Windows: the event reactor is built on Kernel.Event.Source (epoll/kqueue)
// and Kernel.Thread.Executor.Polling — POSIX-only surfaces (swift-executors
// gates Polling !os(Windows)). Gated whole-file to match the IO Completions
// posture; the Windows leg uses the blocking path per IO+File.System+Default.
#if !os(Windows)
    extension Event.Actor {

        enum State: Sendable {
            case running
            case shuttingDown
        }
    }

#endif
