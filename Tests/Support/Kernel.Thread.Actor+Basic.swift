public import Span_Raw_Primitives

extension Kernel.Thread.Actor {

    public func read(
        from descriptor: borrowing Kernel.Descriptor,
        into buffer: Span.Raw.Mutable
    ) throws(Basic.Error) -> Int {
        do throws(Kernel.IO.Read.Error) {
            return try unsafe Kernel.IO.Read.read(descriptor, into: unsafe buffer.base.nonNull)
        } catch {
            throw error.basicError
        }
    }

    public func write(
        to descriptor: borrowing Kernel.Descriptor,
        from buffer: Span.Raw
    ) throws(Basic.Error) -> Int {
        do throws(Kernel.IO.Write.Error) {
            return try unsafe Kernel.IO.Write.write(descriptor, from: unsafe buffer.base.nonNull)
        } catch {
            throw error.basicError
        }
    }

    public func close(_ descriptor: consuming Kernel.Descriptor) {
        do throws(Kernel.Close.Error) {
            try Kernel.Close.close(consume descriptor)
        } catch {

        }
    }

    public var id: Kernel.Thread.ID { Kernel.Thread.ID.current }
}
