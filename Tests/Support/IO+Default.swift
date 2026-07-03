//
//  IO+Default.swift
//  IO Test Support
//
//  Host-adaptive `default()` factory for the Basic test-support domain.
//  Platform preference is open-coded here — each domain (Basic, File,
//  Socket, Server) owns its own chain, since the preferred ordering is
//  domain policy (e.g., File has no events branch; Socket prefers
//  events on Darwin).
//

public import Kernel

extension IO where Capabilities == Basic.Capabilities {
    /// The default `IO<Basic.Capabilities>` for the host — the best
    /// available strategy with a transparent fallback chain.
    ///
    /// Dispatch order:
    ///
    /// | Platform | Order |
    /// |----------|-------|
    /// | **Linux** | completions (io_uring, if `Kernel.IO.Uring.isSupported`) → events (epoll) → blocking |
    /// | **Darwin** | events (kqueue) → blocking |
    /// | **Windows / other** | blocking (IOCP is a future phase) |
    ///
    /// The terminal fallback is always ``blocking()``, which every
    /// supported host provides; this factory never throws.
    public static func `default`() -> IO<Basic.Capabilities> {
        #if os(Linux)
            if Kernel.IO.Uring.isSupported,
                let actor = try? Completion.Actor.shared()
            {
                return .completions(on: actor)
            }
        #endif
        #if !os(Windows)
            if let actor = try? Event.Actor.shared() {
                return .events(on: actor)
            }
        #endif
        return .blocking()
    }
}
