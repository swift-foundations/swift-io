//
//  Event.Error+Kernel.swift
//  swift-io
//
//  Mapping from Kernel.IO.Read.Error / Kernel.IO.Write.Error to
//  Event.Error, used by the events-strategy actor's EAGAIN-retry loop.
//

// Windows: the event reactor is built on Kernel.Event.Source (epoll/kqueue)
// and Kernel.Thread.Executor.Polling — POSIX-only surfaces (swift-executors
// gates Polling !os(Windows)). Gated whole-file to match the IO Completions
// posture; the Windows leg uses the blocking path per IO+File.System+Default.
#if !os(Windows)
extension Kernel.IO.Read.Error {
    /// Semantic mapping to ``Event/Error``.
    ///
    /// `EPIPE` (broken pipe) maps to ``Event/Error/readClosed`` (the reactor's
    /// strategy-level shape for a closed read end). Other cases fold into
    /// ``Event/Error/platform(_:)`` for downstream interpretation.
    @usableFromInline
    package var eventError: Event.Error {
        if code == .POSIX.EPIPE {
            return .readClosed
        }
        return .platform(code)
    }
}

extension Kernel.IO.Write.Error {
    /// Semantic mapping to ``Event/Error``.
    ///
    /// `EPIPE` (broken pipe / peer-reset) maps to ``Event/Error/writeClosed``
    /// (the reactor's strategy-level shape for a closed write end). Other
    /// cases fold into ``Event/Error/platform(_:)`` for downstream
    /// interpretation.
    @usableFromInline
    package var eventError: Event.Error {
        if code == .POSIX.EPIPE {
            return .writeClosed
        }
        return .platform(code)
    }
}

#endif
