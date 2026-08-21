public import Span_Raw_Primitives

extension IO where Capabilities == Basic.Capabilities {

    @inlinable
    public func read(
        from fd: borrowing Kernel.Descriptor,
        into buffer: Span.Raw.Mutable
    ) async throws(Basic.Error) -> Int {
        try await capabilities.read(fd, buffer)
    }

    @inlinable
    public func write(
        to fd: borrowing Kernel.Descriptor,
        from buffer: Span.Raw
    ) async throws(Basic.Error) -> Int {
        try await capabilities.write(fd, buffer)
    }

    @inlinable
    public func close(_ fd: consuming Kernel.Descriptor) async {
        await capabilities.close(consume fd)
    }

    @inlinable
    public func ready(
        from fd: borrowing Kernel.Descriptor,
        interest: Kernel.Event.Interest
    ) async throws(Basic.Error) {
        try await capabilities.ready(fd, interest)
    }

    @inlinable
    public var unownedExecutor: UnownedSerialExecutor {
        runner.executor()
    }
}
