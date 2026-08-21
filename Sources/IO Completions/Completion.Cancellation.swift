import Synchronization

extension Completion {

    public final class Cancellation: Sendable {
        private let _value = Atomic<Bool>(false)

        public init() {}

        deinit {}
    }
}

extension Completion.Cancellation {

    public func set() {
        _value.store(true, ordering: .releasing)
    }

    public var isSet: Bool {
        _value.load(ordering: .acquiring)
    }
}
