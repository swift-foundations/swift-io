//
//  Event.Actor.RetryDecision.swift
//  swift-io
//
//  Classification of Kernel.Event.Driver.Error into a retry policy for
//  the Actor's tick closure. Pure — no side effects; unit-testable
//  without constructing an executor.
//

// Windows: the event reactor is built on Kernel.Event.Source (epoll/kqueue)
// and Kernel.Thread.Executor.Polling — POSIX-only surfaces (swift-executors
// gates Polling !os(Windows)). Gated whole-file to match the IO Completions
// posture; the Windows leg uses the blocking path per IO+File.System+Default.
#if !os(Windows)
    public import Kernel

    extension Event.Actor {
        /// Outcome of classifying a wait failure.
        ///
        /// - `retry`: transient error; retry the poll immediately.
        /// - `yieldAndRetry`: transient error under memory pressure; yield the
        ///   thread before retrying so the scheduler can make progress elsewhere.
        /// - `halt`: unrecognized error; close channel registrations and exit.
        enum RetryDecision: Equatable, Sendable {
            case retry
            case yieldAndRetry
            case halt
        }
    }

    extension Event.Actor.RetryDecision {
        /// Classifies a driver error for the Actor's tick policy.
        ///
        /// ## Mapping
        /// - `EINTR` → `.retry` (signal interrupted the poll; retrying is safe)
        /// - `ENOMEM` → `.yieldAndRetry` (memory pressure; give the scheduler
        ///   a window to reclaim before the next poll)
        /// - `EAGAIN`/`EWOULDBLOCK` (cross-platform via
        ///   `Error_Primitives.Error.Code.POSIX.isEAGAIN`) → `.retry`
        /// - everything else (other platform codes, `.invalidDescriptor`,
        ///   `.notRegistered`) → `.halt`
        init(for error: Kernel.Event.Driver.Error) {
            switch error {
            case .platform(let code) where code == .POSIX.EINTR:
                self = .retry

            case .platform(let code) where code == .POSIX.ENOMEM:
                self = .yieldAndRetry

            case .platform(let code) where Error_Primitives.Error.Code.POSIX.isEAGAIN(code):
                self = .retry

            default:
                self = .halt
            }
        }
    }

#endif
