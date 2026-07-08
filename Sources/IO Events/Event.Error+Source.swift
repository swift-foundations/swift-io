//
//  Event.Error+Source.swift
//  swift-io
//
//  Bridge from Kernel.Event.Driver.Error to Event.Error.
//

// Windows: the event reactor is built on Kernel.Event.Source (epoll/kqueue)
// and Kernel.Thread.Executor.Polling — POSIX-only surfaces (swift-executors
// gates Polling !os(Windows)). Gated whole-file to match the IO Completions
// posture; the Windows leg uses the blocking path per IO+File.System+Default.
#if !os(Windows)
    extension Event.Error {
        /// Creates an IO event error from a kernel event driver error.
        ///
        /// The three kernel cases map directly:
        /// - `platform` → `platform`
        /// - `invalidDescriptor` → `invalidDescriptor`
        /// - `notRegistered` → `notRegistered`
        @inlinable
        package init(_ error: Kernel.Event.Driver.Error) {
            switch error {
            case .platform(let code):
                self = .platform(code)

            case .invalidDescriptor:
                self = .invalidDescriptor

            case .notRegistered:
                self = .notRegistered

            case .unsupportedPlatform:
                self = .platform(.POSIX.ENOTSUP)
            }
        }
    }

#endif
