# IO.Driver Witness Composition

<!--
---
version: 1.1.0
last_updated: 2026-05-31
status: RECOMMENDATION
statusDetail: "Analysis complete; explicit Recommendation = Option A (Single Unified Witness). Four Open Questions remain (non-blocking). Triaged 2026-05-31 per [META-002]; was IN_PROGRESS."
tier: 2
related:
  - swift-io/Research/io-uring-integration-architecture.md
  - swift-io/Research/completion-queue-ownership-redesign.md
  - swift-institute/Research/l1-resource-promotion-event-completion.md
---
-->

## Context

swift-io currently has two separate subsystems for kernel I/O:
- `IO.Event` (readiness/reactor) — uses `Kernel.Event.Source` directly, no IO-level witness
- `IO.Completion` (proactor) — uses `IO.Completion.Driver` witness wrapping kernel resources

These have different threading models (Event: integrated executor+poll, Completion:
separate poll thread + MPSC queue) and different abstraction levels (Event: no witness,
Completion: witness + Handle pattern).

The Kernel.Completion L1 promotion is complete. Both kernel resources now have
clean L1/L3 APIs (`Kernel.Event.Source.platform()`, `Kernel.Completion.platform()`).
swift-io should compose them into a single `IO.Driver` witness.

## Question

How should `IO.Driver` compose `Kernel.Event.Source` and `Kernel.Completion`
into a single witness struct with `bestAvailable()`?

## Evaluation Criteria

| Criterion | Weight | Description |
|-----------|--------|-------------|
| Platform agnosticism | High | No `#if os(...)` in swift-io |
| Testability | High | `IO.Driver.Fake` / `IO.Driver.unimplemented()` for tests |
| Single poll point | High | One blocking call returns both readiness AND completion events |
| Composability | Medium | Clean witness composition, `@Witness` macro compatible |
| Migration cost | Medium | How much existing IO code must change |
| Thread model unification | Medium | One thread for both, or graceful split |

## Analysis

### Current State

**Event side** (`IO.Event.Loop`):
- Loop IS the executor: `SerialExecutor + TaskExecutor`
- Stores `Kernel.Event.Source` directly (no witness layer)
- `poll(deadline:into:)` blocks in kevent/epoll_wait
- Events dispatched to unbounded channel senders
- Jobs drained between polls (actor integration)

**Completion side** (`IO.Completion.Poll`):
- Separate OS thread, NOT an executor
- Uses `IO.Completion.Driver` witness (Handle pattern)
- `poll(handle:deadline:into:)` blocks, then matches tokens to entries
- Results delivered via `CheckedContinuation.resume()` from poll thread

**The gap**: No unified dispatch. If you want both readiness and completion,
you need two threads and two poll loops.

### Option A: Single Unified Witness

One `IO.Driver` with closures spanning both Event and Completion:

```swift
@Witness
public struct Driver {
    // --- Capabilities ---
    public let capabilities: Capabilities

    // --- Lifecycle ---
    let _create: () throws(Error) -> Handle
    let _close: (consuming Handle) -> Void
    let _wakeup: Kernel.Wakeup.Channel

    // --- Readiness (reactor) ---
    let _register: (borrowing Handle, consuming Kernel.Descriptor, Kernel.Event.Interest) throws(Error) -> Kernel.Event.ID
    let _modify: (borrowing Handle, Kernel.Event.ID, Kernel.Event.Interest) throws(Error) -> Void
    let _deregister: (borrowing Handle, Kernel.Event.ID) throws(Error) -> Void
    let _arm: (borrowing Handle, Kernel.Event.ID, Kernel.Event.Interest) throws(Error) -> Void

    // --- Completion (proactor) ---
    let _submit: (borrowing Handle, Kernel.Completion.Submission, borrowing Kernel.Descriptor) throws(Error) -> Void
    let _flush: (borrowing Handle) throws(Error) -> Int

    // --- Unified poll ---
    let _poll: (borrowing Handle, Kernel.Time.Deadline?) throws(Error) -> Poll.Result
}
```

`Poll.Result` carries both readiness events and completion events:

```swift
struct Poll.Result {
    var readiness: [Kernel.Event]        // which fds are ready
    var completions: [Kernel.Completion.Event]  // which operations completed
}
```

**`bestAvailable()` composition**:
- Linux: `Kernel.Event.Source.platform()` (epoll) + `Kernel.Completion.platform()` (io_uring).
  The io_uring eventfd is registered with epoll. One `epoll_wait` wakes for both.
  After wake: dispatch readiness events + `completion.drain()`.
- Darwin: `Kernel.Event.Source.platform()` (kqueue) only. No completion backend.
  `_submit`/`_flush` throw `.unsupported`. Capabilities reflect this.
- Windows (future): IOCP only. No readiness backend. `_register`/`_modify` throw.

**Pros**:
- Single handle, single poll, single thread
- Platform selection in `bestAvailable()`, zero conditionals in swift-io
- `@Witness` gives `unimplemented()` and `Fake` for free
- Capabilities flags tell the caller what's available

**Cons**:
- Large witness (11 closures)
- Readiness-only platforms (Darwin) carry dead completion closures
- Completion-only platforms (Windows) carry dead readiness closures

### Option B: Nested Composition

`IO.Driver` holds two optional sub-witnesses:

```swift
public struct Driver: ~Copyable {
    public let event: Kernel.Event.Source?
    public let completion: Kernel.Completion?
    public let wakeup: Kernel.Wakeup.Channel

    public static func bestAvailable() throws -> Driver { ... }

    public func poll(deadline: Kernel.Time.Deadline?) throws -> Poll.Result {
        // poll event source, drain completions
    }
}
```

**Pros**:
- Clean separation — each sub-resource has its own API
- No dead closures — Optional sub-resources
- poll() is the composition point

**Cons**:
- Not a witness struct — can't use `@Witness` macro
- `~Copyable` (holds ~Copyable resources) — harder to test
- Tighter coupling to kernel types (not just closures)

### Option C: Witness with Capability-Gated Operations

Like Option A but operations are Optional closures:

```swift
@Witness
public struct Driver {
    let _create: () throws(Error) -> Handle
    let _close: (consuming Handle) -> Void
    let _wakeup: () -> Kernel.Wakeup.Channel

    // Optional capabilities
    let _register: ((borrowing Handle, consuming Kernel.Descriptor, Kernel.Event.Interest) throws(Error) -> Kernel.Event.ID)?
    let _submit: ((borrowing Handle, Kernel.Completion.Submission, borrowing Kernel.Descriptor) throws(Error) -> Void)?

    // Always present
    let _poll: (borrowing Handle, Kernel.Time.Deadline?) throws(Error) -> Poll.Result
}
```

**Pros**: No dead closures, capability introspection via nil check
**Cons**: Optional closures complicate call sites, `@Witness` may not handle Optional closures

## Comparison

| Criterion | A: Unified | B: Nested | C: Capability-gated |
|-----------|-----------|-----------|---------------------|
| Platform agnosticism | Strong | Strong | Strong |
| Testability | Best (@Witness) | Harder (~Copyable) | Good |
| Single poll point | Yes | Yes | Yes |
| @Witness compatible | Yes | No | Unclear |
| Dead closures | Yes | No | No |
| API simplicity | Clean | Clean | Noisy (optionals) |
| Migration cost | High | Medium | High |

## Recommendation

**Option A: Single Unified Witness.**

The dead closures are a non-issue — they throw `.unsupported` on platforms where
the capability isn't available. Capabilities flags let consumers check upfront.
The `@Witness` macro gives `unimplemented()` for testing. The flat closure list
is explicit about what IO.Driver provides.

The unified `_poll` is the value proposition. One blocking call, two event sources.
The composition logic (epoll + io_uring drain, kqueue only, IOCP only) lives
inside `bestAvailable()` — the consumer never sees it.

### `bestAvailable()` sketch

```swift
extension IO.Driver {
    public static func bestAvailable() throws(Error) -> Driver {
        let event = try Kernel.Event.Source.platform()
        let completion = try? Kernel.Completion.platform()

        // On Linux: register io_uring eventfd with epoll
        if let completion, let notification = completion.notification {
            try event.register(
                descriptor: notification.descriptor,
                interest: .read
            )
        }

        let wakeup = event.wakeup // Sendable, extracted before transfer

        return Driver(
            capabilities: Capabilities(
                readiness: true,
                completion: completion != nil
            ),
            create: { Handle(event: event, completion: completion) },
            // ... closures delegate to event/completion ...
            poll: { handle, deadline in
                let readinessCount = try event.poll(deadline: deadline, into: &buffer)
                var completions: [Kernel.Completion.Event] = []
                completion?.drain { completions.append($0) }
                return Poll.Result(readiness: buffer, completions: completions)
            }
        )
    }
}
```

### Open Questions

1. **Thread model**: Event.Loop is currently an executor. Does IO.Driver replace
   the Loop, or does the Loop use IO.Driver internally?

2. **Handle contents**: Does Handle wrap both kernel resources, or does the
   factory closure capture them and Handle is just an opaque token?

3. **Error type**: Unified `IO.Driver.Error` or separate event/completion errors?

4. **Notification registration**: The io_uring eventfd registration with epoll
   happens at composition time — is this the factory's job or the caller's?

## References

- `swift-io/Research/io-uring-integration-architecture.md` — original integration plan
- `swift-io/Research/completion-queue-ownership-redesign.md` — Queue architecture
- Kernel.Event.Driver: `swift-kernel-primitives/.../Kernel.Event.Driver.swift`
- Kernel.Completion.Driver: `swift-kernel-primitives/.../Kernel.Completion.Driver.swift`
- IO.Completion.Driver: `swift-io/.../IO.Completion.Driver.swift`
- IO.Event.Loop: `swift-io/.../IO.Event.Loop.swift`
