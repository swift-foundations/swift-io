import Kernel_Completion

extension Completion {

    public struct Entry: ~Copyable {

        public let id: Kernel.Completion.Token

        public let opcode: Kernel.Completion.Submission.Opcode

        @usableFromInline
        var descriptor: Kernel.Descriptor?

        public let flag: Completion.Cancellation

        var _continuation: CheckedContinuation<Kernel.Completion.Event?, Never>?

        public init(
            id: Kernel.Completion.Token,
            opcode: Kernel.Completion.Submission.Opcode,
            descriptor: consuming Kernel.Descriptor?,
            flag: Completion.Cancellation,
            continuation: CheckedContinuation<Kernel.Completion.Event?, Never>
        ) {
            self.id = id
            self.opcode = opcode
            self.descriptor = descriptor
            self.flag = flag
            self._continuation = continuation
        }

        deinit {
            guard let continuation = _continuation else { return }

            continuation.resume(returning: nil)
            preconditionFailure("Completion.Entry dropped without being resolved")
        }
    }
}

extension Completion.Entry {

    public consuming func resolve(with event: Kernel.Completion.Event) {
        _continuation!.resume(returning: event)
        _continuation = nil
    }

    public consuming func resolveAsCancelled() {
        _continuation!.resume(returning: nil)
        _continuation = nil
    }
}
