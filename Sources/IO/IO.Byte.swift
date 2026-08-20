public import Buffer_Primitives
public import Byte_Primitives

extension IO {
    /// Byte-oriented I/O vocabulary.
    public enum Byte {
        /// A duplex channel whose elements are canonical buffer slices of bytes.
        public typealias Channel<Failure: Swift.Error & Sendable> = IO.Channel<
            Buffer.Slice<Byte_Primitives.Byte>, Failure
        >
    }
}
