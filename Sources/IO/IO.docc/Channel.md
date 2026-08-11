# Duplex channels

``IO/Channel`` composes two `Async.Channel` bounded endpoints. It does not own
queues, locks, waiting, cancellation, or backpressure machinery; those remain
the responsibility of `Async.Channel`.

An endpoint owns an ``IO/Channel/inbound`` ``IO/Reader`` and an
``IO/Channel/outbound`` ``IO/Writer``. `Channel.pair(capacity:)` cross-connects
them: one endpoint's writer feeds the other endpoint's reader.

## Lifecycle laws

- `Writer.finish()` half-closes only the peer's inbound direction. Buffered
  elements drain before its reader returns `nil`.
- `Writer.fail(_:)` half-closes only the peer's inbound direction. Buffered
  elements drain before its reader throws the exact declared failure.
- `Reader.finish()` and `Reader.fail(_:)` terminate only the opposite writer.
  A suspended or later writer observes the typed terminal result.
- Every direction is first-terminal-wins. A terminal action in one direction
  never changes the independent reverse direction.
- `shutdown()` orders a successful inbound close before a successful outbound
  close. This rejects new peer sends, then grants the peer normal buffered-drain
  semantics for our outbound close.
- Capacity and cancellation retain the underlying bounded channel's behavior:
  send suspends under backpressure and resumes with the same typed terminal
  result if the opposing reader terminates it.

``IO/Byte/Channel`` fixes the element to `Buffer.Slice<Byte>`.
