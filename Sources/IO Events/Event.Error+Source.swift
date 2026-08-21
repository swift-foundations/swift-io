#if !os(Windows)
    extension Event.Error {

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
