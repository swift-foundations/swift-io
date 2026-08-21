#if !os(Windows)

    public import IO_Events

    extension Event.Failure {

        @usableFromInline
        package var basicError: Basic.Error {
            switch self {
            case .left(.cancelled):
                return .cancelled

            case .left(.shutdown):
                return .shutdown

            case .left(.timeout):
                return .timeout

            case .right(let eventError):
                switch eventError {
                case .platform(let code):
                    return .platform(code)

                case .invalidDescriptor:
                    return .platform(.POSIX.EBADF)

                case .alreadyRegistered, .notRegistered, .deregistered:
                    return .platform(.POSIX.EINVAL)

                case .readClosed, .writeClosed:
                    return .brokenPipe

                case .notConnected:
                    return .platform(.POSIX.EINVAL)
                }
            }
        }
    }

#endif
