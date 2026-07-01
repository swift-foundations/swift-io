# Split Cancellation Propagation

<!--
---
version: 1.0.0
last_updated: 2026-03-30
status: RECOMMENDATION
---
-->

## Context

Phase 3 of the Full-Duplex refactor introduced `IO.Event.Channel.split()`, which produces independent `Reader` and `Writer` halves. Four edge-case tests are disabled:

| Test | Disabled reason |
|------|----------------|
| `cancelRead` | Task.detached cancellation allegedly does not propagate through Cell.take() |
| `cancelWrite` | Same |
| `selectorShutdown` | Same (but this test uses selector shutdown, not task cancellation) |
| `deinitFallback` | `assertionFailure` in Reader deinit is fatal in debug mode |

All three cancellation/shutdown tests use `Ownership.Transfer.Cell` to move a `~Copyable` Reader/Writer into a `Task.detached` closure, then rely on external action (cancel or shutdown) to terminate a suspended operation. The hypothesis recorded in the `.disabled(...)` messages is that `Cell.take()` breaks cancellation propagation.

Source: `HANDOFF-split-cancellation-propagation.md` in swift-io.

## Question

1. Does `Ownership.Transfer.Cell.token().take()` break the task's cancellation handler chain?
2. What is the actual root cause of the test hangs?
3. Is there an alternative pattern for transferring `~Copyable` values across `@Sendable` boundaries that preserves cancellation?
4. Can `deinitFallback` be tested without triggering `assertionFailure`?

## Analysis

### Question 1: Cell.take() and cancellation

**Verdict: Cell.take() is innocent.**

`Ownership.Transfer.Cell.Token.take()` (`Ownership.Transfer.Cell.swift:79`) is a pure synchronous function:

```swift
public func take() -> T {
    _box.take()
}
```

`_Box.take()` (`Ownership.Transfer._Box.swift:136-156`) performs an atomic CAS (`State.full` -> `State.taken`), moves the value out of heap storage, and deallocates. Total time: nanoseconds. No interaction with Swift's structured concurrency runtime, no effect on `Task.isCancelled`, no modification of the cancellation handler chain.

The token is `Sendable` + `Copyable`. Capturing it in a `Task.detached` closure is a standard value capture. The ~Copyable return value (`Reader`) becomes a local variable inside the closure -- this does not affect the task's concurrency identity.

**Cell.take() cannot break cancellation.**

### Question 2: Root cause analysis

#### Call chain trace

```
Task.detached {
  token.take()                          // synchronous, ~ns
  reader.read(into: buf)                // IO.Event.Channel.Reader.swift:60
    Kernel.IO.Read.read(...)            // syscall, returns EAGAIN (~us)
    .wouldBlock -> arm()                // IO.Event.Channel.Reader.swift:101
      registrationQueue.enqueue(...)    // synchronous, ~ns
      wakeupChannel.wake()             // synchronous, ~ns
      ends.receiver.receive()           // Async.Channel.Unbounded.Receiver.swift:72
        receiveTake()                   // fast path: buffer empty -> .wait
        Task.isCancelled               // <-- checkpoint 1
        withTaskCancellationHandler {   // <-- registers onCancel
          withUnsafeContinuation {
            receiveWait(cont)           // <-- stores continuation in slot
            .wait -> break              // task suspends here
          }
        } onCancel: {
          receiveStop()                 // <-- extracts continuation from slot
          cont.resume(.cancelled)       // <-- resumes task
        }
}
```

Total time from task start to suspension: ~10-100 microseconds. The 50ms sleep in the tests provides a 500x-5000x margin.

#### The receiver state-machine completeness problem

The core issue is not specific to `withUnsafeContinuation` timing or `Task.detached` semantics. It is a **receiver state-machine completeness problem**:

> Cancellation can be observed by the handler before the receive state has become cancellation-visible.

The invariant that must hold:

> After cancellation registration becomes active, either cancellation resumes the waiter immediately, **or** the receiver state records cancellation durably for the next receive transition to observe.

The current state machine violates this invariant. `receiveStop()` (`Async.Channel.Unbounded.State.swift:172-180`) treats "no continuation stored" as "nothing to do" — silently discarding the cancellation signal:

```swift
mutating func receiveStop() -> Receive.Stop {
    switch slot {
    case .wait(let cont):
        slot = .none
        return .stop(cont)
    case .none:
        return .none     // <-- cancellation is silently lost
    }
}
```

**Concrete manifestation**: `onCancel` fires, acquires the mutex, calls `receiveStop()`, finds `slot == .none` (continuation not yet stored), returns `.none`. Then `receiveWait(cont)` acquires the mutex, stores the continuation, returns `.wait`. The continuation is never resumed.

The race window between cancellation handler registration and continuation storage is nanoseconds, but the design obligation sits at the state-machine boundary: the `Slot` type must be able to represent "cancellation arrived before the waiter" as a durable state.

#### Why the unbounded channel's own cancellation test passes

`Async.Channel.Unbounded Tests.swift:186` uses `Async.Barrier(parties: 2)` for synchronization. The barrier guarantees the task has **suspended** before `cancel()` is called. By that point, the continuation IS stored in the slot, so `receiveStop()` always finds it.

The split tests use `Task.sleep(for: .milliseconds(50))` instead. While 50ms is far more than enough for the task to suspend under normal conditions, it does not provide a formal guarantee.

#### Practical assessment

Under normal conditions (thread pool not saturated, no pathological scheduling delays), the 50ms sleep ensures the continuation is stored well before `cancel()` fires. The race window is nanoseconds. The probability of hitting it is negligible in manual testing but nonzero in high-volume CI.

However, for a channel primitive in a "timeless infrastructure" project, a nanosecond-window race is still a correctness bug. It should be fixed.

#### Selector shutdown test

The `selectorShutdown` test is **qualitatively different** from the cancellation tests. It uses `selector.shutdown()` which closes all channel senders via `Sender.close()`. The `close()` state machine transition (`Async.Channel.Unbounded.State.swift:193-208`) handles both timing cases:

- **Receiver suspended**: extracts continuation, resumes with `.closed` -> `arm()` gets `nil` -> throws `.shutdownInProgress`
- **Receiver not yet waiting**: sets `_closed = true` -> next `receiveTake()` fast path returns `.end`

Both paths terminate correctly. The `.disabled(...)` message on this test is cargo-culted from the cancellation tests — it shares the same wording but does not use task cancellation at all. This test should be re-evaluated independently after the state machine fix rather than assumed to share the same root cause.

### Question 3: Alternative ~Copyable transfer patterns

Since Cell.take() is not the problem, no alternative transfer pattern is needed. The Cell/Token pattern is the correct approach for moving `~Copyable` values into `@Sendable` closures.

For completeness, alternatives considered:

| Pattern | Viable | Reason |
|---------|--------|--------|
| `Ownership.Transfer.Cell` | Yes (current) | Correct: synchronous, no concurrency interaction |
| `UnsafeMutablePointer` + manual lifetime | Yes but worse | Unsafe, no atomic one-shot enforcement |
| `ManagedBuffer` subclass | No | Overkill, same ARC semantics as Cell's _Box |
| Capture reader directly | No | `~Copyable` types cannot be captured in `@Sendable` closures |

### Question 4: deinitFallback test

The `Reader.deinit` (`IO.Event.Channel.Reader.swift:41-49`) calls `assertionFailure(...)`. In Swift:

| Optimization | `assertionFailure` behavior |
|-------------|---------------------------|
| `-Onone` (debug) | Runtime trap (fatal) |
| `-O` (release) | No-op |
| `-Ounchecked` | Undefined behavior |

The test validates the release-mode fallback path where deinit fires `abandon()` without crashing. It cannot run in debug because `assertionFailure` is fatal.

**Recommended approach**: Conditional compilation.

```swift
#if !DEBUG
@Test(
    "halves dropped without close trigger deinit fallback",
    .timeLimit(.minutes(1))
)
func deinitFallback() async throws {
    // ... existing test body ...
}
#endif
```

This is the simplest approach. The test exists in source but only compiles (and runs) in release builds (`swift test -c release`).

Alternatives considered:

| Approach | Viable | Trade-off |
|----------|--------|-----------|
| `#if !DEBUG` guard | **Recommended** | Clean, no production code changes |
| `.enabled(if:)` with runtime check | Partial | Swift Testing doesn't expose optimization level |
| Replace `assertionFailure` with logging | No | Weakens the "you forgot to call close()" safety net |
| Test-specific deinit behavior (protocol) | No | Production code change for test support |

## Outcome

**Status**: RECOMMENDATION

### Root cause

The hypothesis that `Cell.take()` breaks cancellation is **incorrect**. The actual issue is a race condition in `Async.Channel.Unbounded.Receiver.receive()` where `onCancel` can fire before `receiveWait()` stores the continuation, silently losing the cancellation signal.

### Recommended fix: add `.cancelled` state to channel Slot

**Location**: `Async.Channel.Unbounded.State.swift` in swift-async-primitives

Add a `.cancelled` case to the `Slot` enum so `receiveStop()` can record cancellation for a subsequent `receiveWait()` to observe:

```swift
// Slot enum — add .cancelled case
@usableFromInline
enum Slot: Sendable {
    case none
    case wait(Receive.Continuation)
    case cancelled    // NEW: cancellation requested before continuation stored
}
```

```swift
// receiveStop — record cancellation when no continuation found
@usableFromInline
mutating func receiveStop() -> Receive.Stop {
    switch slot {
    case .wait(let cont):
        slot = .none
        return .stop(cont)
    case .none:
        slot = .cancelled     // NEW: record for receiveWait to observe
        return .none
    case .cancelled:
        return .none
    }
}
```

```swift
// receiveWait — check for pre-recorded cancellation
@usableFromInline
mutating func receiveWait(_ cont: Receive.Continuation) -> Receive.Step {
    // Check if cancellation already arrived
    if case .cancelled = slot {
        slot = .none
        return .cancelled     // NEW: Receive.Step case
    }

    precondition({
        if case .none = slot { return true }
        return false
    }(), "Single-suspended-receiver invariant violated")

    if let element = buffer.take(from: .front) {
        return .val(element)
    }
    if _closed {
        return .end
    }

    slot = .wait(cont)
    return .wait
}
```

```swift
// Receive.Step — add .cancelled case
@usableFromInline
enum Step: ~Copyable, @unchecked Sendable {
    case val(Element)
    case end
    case wait
    case cancelled    // NEW
}
```

**Callers** (`receive()` and `Iterator.next()`) add a case to the switch inside `withUnsafeContinuation`:

```swift
case .cancelled:
    continuation.resume(returning: .cancelled)
```

**Every transition that currently treats `slot` as binary `none | wait(cont)` must absorb `.cancelled` correctly.** One forgotten transition reintroduces a different edge-case bug.

| Transition | Current `slot` handling | `.cancelled` behavior |
|------------|------------------------|----------------------|
| `send()` | `.wait` -> deliver, `.none` -> buffer | `.cancelled` -> buffer (no waiting receiver) |
| `close()` | `.wait` -> resume `.closed`, `.none` -> no-op | `.cancelled` -> no-op (next `receiveWait` handles it) |
| `receiveTake()` | Does not inspect `slot` | No change needed |
| `receiveWait()` | Precondition `slot == .none` | Check `.cancelled` first, clear and return `.cancelled` |
| `receiveStop()` | `.wait` -> extract, `.none` -> no-op | `.cancelled` -> no-op (already recorded) |
| `Iterator.next()` body | Same `receiveWait` + switch | Add `.cancelled` case: resume continuation |
| Debug assertions | `slot == .none` assumed to mean "idle" | `.cancelled` is also a valid non-waiting state |

### Recommended test changes

1. **Replace timing-based synchronization**: Use `Async.Barrier` where possible. Place `await barrier.arrive()` inside the detached task just before the read/write call, and in the parent just before cancel/shutdown.

2. **Re-enable `selectorShutdown`**: This test's hang mechanism (sender close) is handled correctly by the state machine's `close()` → `receiveTake()` fast path. It likely works as-is, independent of the cancellation race. Update the `.disabled(...)` message to reflect the actual concern (if any remains after re-testing).

3. **Conditional `deinitFallback`**: Wrap in `#if !DEBUG` so it runs only in release mode where `assertionFailure` is a no-op.

### Verification plan

1. Apply the `.cancelled` state fix to `Async.Channel.Unbounded.State`
2. Update `receive()` and `Iterator.next()` to handle `.cancelled` step
3. Update `send()` and `close()` to treat `.cancelled` like `.none`
4. Run `swift test` in swift-async-primitives — existing cancellation test must still pass
5. Re-enable the four split tests (remove `.disabled(...)`)
6. Run `swift test` in swift-io — all four tests must pass
7. Stress-test: run the cancellation tests in a loop (100+ iterations) to verify no race

## References

- `Tests/IO Events Tests/IO.Event.Channel.Split.Tests.swift` — disabled tests
- `Sources/IO Events/IO.Event.Channel.Reader.swift:96-122` — `arm()` method
- `swift-async-primitives/.../Async.Channel.Unbounded.Receiver.swift:72-130` — `receive()` with `withTaskCancellationHandler`
- `swift-async-primitives/.../Async.Channel.Unbounded.State.swift:172-180` — `receiveStop()` missing `.cancelled` state
- `swift-async-primitives/Tests/.../Async.Channel.Unbounded Tests.swift:186-213` — working cancellation test using `Async.Barrier`
- `swift-ownership-primitives/.../Ownership.Transfer.Cell.swift` — Cell + Token (exonerated)
- SE-0304 (Structured Concurrency) — `withTaskCancellationHandler` semantics
