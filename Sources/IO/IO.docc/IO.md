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

## Cancellable descriptor operations

`Event.Actor.run(borrowing:interest:operation:)` is the structured cancellable
surface for descriptor readiness. It creates one exact event registration,
wakes the event source on task cancellation, removes the exact waiter,
deregisters, and physically joins the one-shot nonblocking attempt before the
descriptor borrow ends. The caller may consume or close the descriptor only
after the method returns.

The operation closure is `sending` and nonescaping. It is transferred once to
`Kernel.Thread.run`; it is not `@Sendable` because no concurrent invocation is
possible. Only the cancellation wake endpoint is `@Sendable`, as Swift task
cancellation may invoke that endpoint concurrently with the event wait.

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
