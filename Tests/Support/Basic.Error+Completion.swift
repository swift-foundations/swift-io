//
//  Basic.Error+Completion.swift
//  swift-io
//
//  Map Completion.Failure (strategy-level) onto Basic.Error (domain-
//  level). Lives in IO Basic so neither IO Completions nor IO Core
//  needs to know about Basic.Error.
//

#if !os(Windows)

    public import IO_Completions

    extension Completion.Failure {
        /// Map a proactor failure onto the fd-generic ``Basic/Error``.
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
