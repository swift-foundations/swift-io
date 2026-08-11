public import Async_Channel_Primitives
public import Index_Primitives

extension IO {
    /// A full-duplex in-memory transport composed from two directional channels.
    ///
    /// `inbound` is this endpoint's receive half and `outbound` is its send half.
    /// A pair wires each outbound half to the other endpoint's inbound half.
    public struct Channel<Element: ~Copyable, Failure: Swift.Error & Sendable>: ~Copyable, Sendable {
        /// The typed outcome of an endpoint operation.
        public typealias Error = Async.Channel<Element, Failure>.Error

        /// This endpoint's single-consumer receive half.
        public var inbound: Reader<Element, Failure>

        /// This endpoint's copyable send half.
        public let outbound: Writer<Element, Failure>

        /// Composes an endpoint from an inbound receive half and outbound send half.
        public init(
            inbound: consuming Reader<Element, Failure>,
            outbound: Writer<Element, Failure>
        ) {
            self.inbound = consume inbound
            self.outbound = outbound
        }

        /// Creates two endpoints whose outbound halves feed the other endpoint's inbound half.
        public static func pair(
            capacity: Index<Element>.Count
        ) -> (consuming Self, consuming Self) {
            var left = Async.Channel<Element, Failure>.Bounded(capacity: capacity)
            var right = Async.Channel<Element, Failure>.Bounded(capacity: capacity)

            return (
                Self(inbound: consume right.receiver, outbound: left.sender),
                Self(inbound: consume left.receiver, outbound: right.sender)
            )
        }

        /// Successfully closes this endpoint's receive half before its send half.
        ///
        /// The inbound close rejects peer sends; the outbound close lets the peer drain
        /// buffered elements before observing end-of-stream. Each directional channel
        /// retains first-terminal-wins semantics.
        public func shutdown() {
            inbound.finish()
            outbound.finish()
        }
    }
}
