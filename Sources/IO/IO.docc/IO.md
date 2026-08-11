# ``IO``

@Metadata {
    @DisplayName("IO")
    @TitleHeading("Swift Foundations")
}

The strategy-only asynchronous I/O runtime: two actor-backed execution
strategies — ``Event``'s reactor (epoll/kqueue readiness polling) and
``Completion``'s proactor (`io_uring`-style completion queues) — plus a
host-adaptive selector, re-exported together with the shared `IO Primitives`
vocabulary.

## When to use this

Reach for this package when a domain package (a file system, a socket layer,
a server) needs an asynchronous I/O runtime to build its capabilities on —
`IO` supplies the strategy runtimes (the actor that owns the reactor or
proactor executor) and the host-adaptive selection between them, but defines
no I/O domain itself: domain packages such as `swift-file-system` and
`swift-sockets` define their own `Capabilities` and compose per-strategy
factories on top of this package. Depend on `IO Events` or `IO Completions`
directly only when a caller needs exactly one strategy rather than the
host-adaptive choice.

## Cancellable readiness

`Event.Actor.enlist(borrowing:interest:operation:)` is the Event strategy's smallest
cross-package construction primitive. It is nonisolated and returns the generic `IO.Operation`
and result-free `IO.Completion` owners from IO Primitives. The actor creates one
distinct owned event registration and ends the caller's descriptor borrow before
returning, before the caller can yield or reenter. A thread-safe Event-owned
queue transfers the already-owned request to the polling actor. Cancellation
may win before actor admission; it closes that exact waiter and wakes the event source;
completion is acknowledged only after exact removal and deregistration.

The supplied sending operation runs once against a separately owned execution
descriptor after readiness. Domain packages therefore retain their file,
socket, or accept policy without extending the caller's descriptor borrow.
Completion is signalled only after cancellation-before-admission or physical
worker join and exact deregistration. The shared cancellation action is the
only `@Sendable` closure; result and completion remain single-owner closures.

There is deliberately no corresponding cancellable arbitrary-blocking syscall
surface. Such a syscall has no generic wake law. Consumers choose the event or
completion strategy for cancellability, or an explicitly non-cancellable
blocking capability with different semantics.

## Topics

### Related packages

- [swift-kernel](https://github.com/swift-foundations/swift-kernel) — the
  syscall-level event and completion sources these strategies poll.
- [swift-executors](https://github.com/swift-foundations/swift-executors) —
  the polling and completion executors the strategy actors own.
