//
//  Basic.Error.swift
//  swift-io
//

extension Basic {
    /// Error type for basic byte operations on ``Kernel/Descriptor``.
    ///
    /// Domain-agnostic across the fd types used with these capabilities
    /// (pipe, file, socket, eventfd, terminal, ...). Socket-flavored
    /// conditions like `ECONNRESET` and `ENOTCONN` live in swift-sockets'
    /// `Sockets.Error`; use that type when working at the TCP/socket
    /// layer.
    public enum Error: Swift.Error, Equatable {
        /// Write side is closed (EPIPE). Fires for pipe/FIFO writes with
        /// a closed read end and for socket writes with a closed peer —
        /// a genuinely fd-generic condition.
        case brokenPipe

        /// Operation timed out.
        case timeout

        /// Task was cancelled.
        case cancelled

        /// The I/O runtime is shutting down.
        case shutdown

        /// Platform error code (POSIX errno or Win32).
        case platform(Error_Primitives.Error.Code)
    }
}
