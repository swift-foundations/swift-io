public import Async_Channel_Primitives

extension IO {
    /// The copyable outbound half of an ``IO/Channel``.
    public typealias Writer<Element: ~Copyable, Failure: Swift.Error & Sendable> = Async.Channel<
        Element, Failure
    >.Sender
}
