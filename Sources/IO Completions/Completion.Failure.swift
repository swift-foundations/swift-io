#if !os(Windows)

    extension Completion {

        public enum Failure: Swift.Error, Equatable {

            case cancelled

            case invalidDescriptor

            case tooManyOpen

            case platform(Error_Primitives.Error.Code)

            case kernel(Kernel.Completion.Error)
        }
    }

    extension Kernel.Descriptor.Duplicate.Error {

        public var completionFailure: Completion.Failure {
            switch self {
            case .handle: .invalidDescriptor
            case .tooManyOpen: .tooManyOpen
            case .platform(let e): .platform(e.code)
            }
        }
    }

    extension Error_Primitives.Error {

        public var completionFailure: Completion.Failure {
            .platform(self.code)
        }
    }

#endif
