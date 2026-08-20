public import Async_Channel_Primitives

extension IO {
    /// The single-consumer inbound half of an ``IO/Channel``.
    public typealias Reader<Element: ~Copyable, Failure: Swift.Error & Sendable> = Async.Channel<
        Element, Failure
    >.Receiver
}
