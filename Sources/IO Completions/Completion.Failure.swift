//
//  Completion.Failure.swift
//  swift-io
//
//  Strategy-level failure surface for the completions proactor actor.
//  Domain-agnostic by design — per-domain factories map this onto their
//  own error taxonomy.
//

#if !os(Windows)

    extension Completion {
        /// Failure surface for completions-strategy actor operations.
        ///
        /// Represents either a task-cancellation terminal (both CQEs
        /// consumed per supervisor constraint #2) or a non-cancellation
        /// error sourced from submission, descriptor duplication, or the
        /// kernel's CQE result.
        public enum Failure: Swift.Error, Equatable {
            /// The awaiting task was cancelled; the original SQE's CQE
            /// and the cancel CQE have both been consumed.
            case cancelled

            /// The descriptor handle was invalid (EBADF).
            case invalidDescriptor

            /// The process ran out of file descriptors (EMFILE).
            case tooManyOpen

            /// Platform error code from a completion event result.
            case platform(Error_Primitives.Error.Code)

            /// Error from the kernel completion driver (submit/flush/drain
            /// paths). The kernel's own typed-error surface is exposed
            /// here so the proactor does not need to pick a lossy code.
            case kernel(Kernel.Completion.Error)
        }
    }

    // MARK: - Kernel error mappings

    extension Kernel.Descriptor.Duplicate.Error {
        /// Map descriptor-dup failures onto ``Completion/Failure``.
        public var completionFailure: Completion.Failure {
            switch self {
            case .handle: .invalidDescriptor
            case .tooManyOpen: .tooManyOpen
            case .platform(let e): .platform(e.code)
            }
        }
    }

    extension Error_Primitives.Error {
        /// Map a kernel error code (from a CQE result) onto
        /// ``Completion/Failure``.
        public var completionFailure: Completion.Failure {
            .platform(self.code)
        }
    }

#endif
