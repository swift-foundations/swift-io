#if !os(Windows)
    public import Kernel

    extension Event {

        public enum Error: Swift.Error, Equatable {

            case platform(Error_Primitives.Error.Code)

            case invalidDescriptor

            case alreadyRegistered

            case notRegistered

            case deregistered

            case readClosed

            case writeClosed

            case notConnected
        }
    }

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
