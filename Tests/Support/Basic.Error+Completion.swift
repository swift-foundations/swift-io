#if !os(Windows)

    public import IO_Completions

    extension Completion.Failure {

        @usableFromInline
        package var basicError: Basic.Error {
            switch self {
            case .cancelled:
                return .cancelled

            case .invalidDescriptor:
                return .platform(.POSIX.EBADF)

            case .tooManyOpen:
                return .platform(.POSIX.EMFILE)

            case .platform(let code):
                if code == Error_Primitives.Error.Code.POSIX.EPIPE { return .brokenPipe }
                return .platform(code)

            case .kernel:
                return .platform(.POSIX.EIO)
            }
        }
    }

#endif
