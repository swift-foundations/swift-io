//
//  Event.Error.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

// Windows: the event reactor is built on Kernel.Event.Source (epoll/kqueue)
// and Kernel.Thread.Executor.Polling — POSIX-only surfaces (swift-executors
// gates Polling !os(Windows)). Gated whole-file to match the IO Completions
// posture; the Windows leg uses the blocking path per IO+File.System+Default.
#if !os(Windows)
public import Kernel

extension Event {
    /// Leaf errors for non-blocking I/O operations.
    ///
    /// These are operational failures at the I/O boundary. Lifecycle concerns
    /// (shutdown, cancellation) are wrapped in `Async.Lifecycle.Error<Error>`.
    ///
    /// ## Error Categories
    /// - **Platform errors**: Direct OS error codes (`errno` or Win32)
    /// - **Descriptor errors**: Invalid or misused descriptors
    /// - **Half-close errors**: Operations on closed sides
    ///
    /// ## Usage
    /// ```swift
    /// func operation() async throws(Async.Lifecycle.Error<Event.Error>)
    /// ```
    ///
    /// ## Note on `wouldBlock`
    /// The `wouldBlock` error is **internal only** and never exposed publicly.
    /// It is consumed by retry loops and converted to "wait for readiness".
    public enum Error: Swift.Error, Equatable {
        // MARK: - Platform Errors

        /// Platform error code (POSIX errno or Win32 error).
        case platform(Error_Primitives.Error.Code)

        // MARK: - Descriptor Errors

        /// The descriptor is invalid (closed, not a socket, etc.).
        case invalidDescriptor

        /// The descriptor is already registered with this selector.
        case alreadyRegistered

        /// The descriptor is not registered with this selector.
        case notRegistered

        /// The descriptor was deregistered while an operation was pending.
        ///
        /// This occurs when `deregister()` is called while a waiter is armed.
        /// The waiter is drained with this error rather than dropped.
        case deregistered

        // MARK: - Half-Close Errors

        /// Read operation after the read side was closed.
        ///
        /// Note: In practice, reads after `shutdownRead()` return 0 (EOF)
        /// rather than throwing. This error is for protocol violations.
        case readClosed

        /// Write operation after the write side was closed.
        case writeClosed

        // MARK: - Connection Errors

        /// Operation requires a connected socket but the socket is not connected.
        ///
        /// For UDP sockets, this occurs when calling `send()` or `recv()`
        /// without a prior call to `connect(to:)`.
        case notConnected
    }
}

// MARK: - CustomStringConvertible

extension Event.Error: CustomStringConvertible {
    public var description: Swift.String {
        switch self {
        case .platform(let code):
            return "Platform error (\(code))"
        case .invalidDescriptor:
            return "Invalid descriptor"
        case .alreadyRegistered:
            return "Already registered"
        case .notRegistered:
            return "Not registered"
        case .deregistered:
            return "Deregistered while operation pending"
        case .readClosed:
            return "Read side closed"
        case .writeClosed:
            return "Write side closed"
        case .notConnected:
            return "Socket not connected"
        }
    }
}

#endif
