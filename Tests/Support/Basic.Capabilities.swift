public import Span_Raw_Primitives

extension Basic {

    public struct Capabilities: Sendable {

        public let read:
            @Sendable (
                borrowing Kernel.Descriptor,
                Span.Raw.Mutable
            ) async throws(Basic.Error) -> Int

        public let write:
            @Sendable (
                borrowing Kernel.Descriptor,
                Span.Raw
            ) async throws(Basic.Error) -> Int

        public let close: @Sendable (consuming Kernel.Descriptor) async -> Void

        public let ready:
            @Sendable (
                borrowing Kernel.Descriptor,
                Kernel.Event.Interest
            ) async throws(Basic.Error) -> Void

        public init(
            read:
                @Sendable @escaping (
                    borrowing Kernel.Descriptor,
                    Span.Raw.Mutable
                ) async throws(Basic.Error) -> Int,
            write:
                @Sendable @escaping (
                    borrowing Kernel.Descriptor,
                    Span.Raw
                ) async throws(Basic.Error) -> Int,
            close: @Sendable @escaping (consuming Kernel.Descriptor) async -> Void,
            ready:
                @Sendable @escaping (
                    borrowing Kernel.Descriptor,
                    Kernel.Event.Interest
                ) async throws(Basic.Error) -> Void
        ) {
            self.read = read
            self.write = write
            self.close = close
            self.ready = ready
        }
    }
}
