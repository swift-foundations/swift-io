//
//  Basic.Error+Kernel.swift
//  swift-io
//
//  Shared mapping from Kernel.IO.Read.Error and Kernel.IO.Write.Error to
//  Basic.Error. Used by the blocking and events strategies to surface
//  strategy-agnostic error semantics.
//

import Kernel

// MARK: - Kernel Error → Basic.Error Mapping

extension Kernel.IO.Read.Error {
    /// Semantic mapping to ``Basic/Error``.
    ///
    /// `EPIPE` (broken pipe) maps to ``Basic/Error/brokenPipe`` (fd-generic,
    /// fires on pipes too). Other codes — including `ECONNRESET`, which is
    /// TCP-specific and whose precise semantic lives in swift-sockets'
    /// `Sockets.Error.connectionReset` — fold into ``Basic/Error/platform(_:)``;
    /// at the swift-io layer the raw platform code is the best we can preserve.
    @usableFromInline
    package var basicError: Basic.Error {
        if code == .POSIX.EPIPE {
            return .brokenPipe
        }
        return .platform(code)
    }
}

extension Kernel.IO.Write.Error {
    /// Semantic mapping to ``Basic/Error``.
    ///
    /// `EPIPE` (broken pipe / peer-reset) maps to ``Basic/Error/brokenPipe``
    /// (fd-generic, fires on pipes too). Other codes — including `ECONNRESET`,
    /// which is TCP-specific and whose precise semantic lives in swift-sockets'
    /// `Sockets.Error.connectionReset` — fold into ``Basic/Error/platform(_:)``;
    /// at the swift-io layer the raw platform code is the best we can preserve.
    @usableFromInline
    package var basicError: Basic.Error {
        if code == .POSIX.EPIPE {
            return .brokenPipe
        }
        return .platform(code)
    }
}
