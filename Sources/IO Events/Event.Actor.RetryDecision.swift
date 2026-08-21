#if !os(Windows)
    import Kernel

    extension Event.Actor {

        enum RetryDecision: Equatable, Sendable {
            case retry
            case yieldAndRetry
            case halt
        }
    }

    extension Event.Actor.RetryDecision {

        init(for error: Kernel.Event.Driver.Error) {
            switch error {
            case .platform(let code) where code == .POSIX.EINTR:
                self = .retry

            case .platform(let code) where code == .POSIX.ENOMEM:
                self = .yieldAndRetry

            case .platform(let code) where Error_Primitives.Error.Code.POSIX.isEAGAIN(code):
                self = .retry

            default:
                self = .halt
            }
        }
    }

#endif
