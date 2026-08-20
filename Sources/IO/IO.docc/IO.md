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

## Topics

### Related packages

- [swift-kernel](https://github.com/swift-foundations/swift-kernel) — the
  syscall-level event and completion sources these strategies poll.
- [swift-executors](https://github.com/swift-foundations/swift-executors) —
  the polling and completion executors the strategy actors own.
