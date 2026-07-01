//
//  Event.Error+Source.swift
//  swift-io
//
//  Bridge from Kernel.Event.Driver.Error to Event.Error.
//


extension Event.Error {
    /// Creates an IO event error from a kernel event driver error.
    ///
    /// The three kernel cases map directly:
    /// - `platform` → `platform`
    /// - `invalidDescriptor` → `invalidDescriptor`
    /// - `notRegistered` → `notRegistered`
    @inlinable
    init(_ error: Kernel.Event.Driver.Error) {
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
