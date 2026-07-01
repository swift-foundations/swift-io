# Completion Queue Ownership Redesign

<!--
---
version: 2.0.0
last_updated: 2026-04-02
status: CONVERGED
tier: 1
---
-->

## Context

The Completion Queue's Runtime actor hangs indefinitely on task cancellation. The drain loop (`while let event = await bridge.next()`) only processes cancelled entries as a side-effect of bridge events arriving. When no completion events flow from the poll thread, the Runtime actor never wakes to process cancellations.

This is not an implementation bug. It is an architectural failure: **split ownership of operation lifecycle between two serialization domains (actor + poll thread) connected by a one-way channel (bridge).**

This is a `select` problem. Two event sources (completions from poll thread, cancellations from client tasks) must converge on one consumer (Runtime actor) that can only listen to one source at a time. Go has `select`, Tokio has `tokio::select!`, Swift has nothing equivalent.

## Question

How should the Completion Queue's concurrency architecture be redesigned to eliminate the notification gap while reducing unnecessary complexity?

## Investigation

Collaborative discussion between Claude (Anthropic) and ChatGPT (OpenAI), converged in 3 rounds. Critical review and Apple HTTP API pattern analysis applied post-convergence.

Full transcript: `/tmp/swift-io-concurrency-redesign-transcript.md`

### Principle

**Collapse lifecycle authority onto the existing serialization point.**

The poll thread is already single-threaded and the sole consumer of kernel completions. It is the natural serialization point. The Runtime actor is a second serialization domain layered on top, connected by a one-way bridge. The hang is evidence that this split ownership is architecturally wrong, not just inconvenient.

### Why the actor was unnecessary for Completions

The Completion Queue has 1:1 operation-to-waiter mapping. No fan-out. Each operation has exactly one completion path. The actor adds indirection without adding value.

Contrast with the Events Selector, which dispatches one poll event to multiple channels (read, write, priority waiters). That fan-out justifies an actor. The Selector keeps its actor.

### The terminal law

**The first terminal outcome the poll thread commits to an entry wins. No other thread may commit or resume.**

This is stronger than the old "completion-wins" slogan, which was implementation-dependent (completion checked first in loop). The new law is authority-based: the poll thread is the sole arbiter.

### Per-operation lifecycle

Four named phases, single-thread transitions (no cross-thread atomic state machine):

| Phase | Location | Owner | Cancellation visible? |
|-------|----------|-------|-----------------------|
| `published` | MPSC queue | client | yes (flag set, poll thread sees on dequeue) |
| `registered` | poll thread's table | poll thread | yes (flag set, poll thread sees on next check) |
| `resolved` | storage.completion | poll thread | n/a (already resolved) |
| `retired` | removed from table | n/a | n/a |

Only the poll thread may advance past `published`. External threads may only set cancellation intent.

### Cross-thread primitive

`IO.Completion.Cancellation.Flag` — a `final class` wrapping `Atomic<Bool>`.

`Atomic<Bool>` is `~Copyable` in Swift's `Synchronization` module, so it cannot be directly embedded in a value type that is both enqueued to an MPSC queue and captured by an `onCancel` closure. A reference type wrapper is required for sharing.

This is the minimal replacement for the old six-state `Waiter` class: one class, one boolean, one method (`set()`), one read (`isSet`). The Waiter is not eliminated — it is reduced from a six-state machine with Resume/Take accessor namespaces to a single-flag cell.

```swift
/// Cancellation intent flag shared between client and poll thread.
///
/// Written once by `onCancel` (arbitrary thread), read by poll thread.
/// `Sendable`: safe to share across isolation boundaries.
public final class Flag: @unchecked Sendable {
    private let _value = Atomic<Bool>(false)
    
    public func set() { _value.store(true, ordering: .releasing) }
    public var isSet: Bool { _value.load(ordering: .acquiring) }
}
```

Naming: `IO.Completion.Cancellation.Flag` per [API-NAME-001] Nest.Name pattern, matching `IO.Completion.Poll.Shutdown.Flag`.

### Type separation

Both types enforce exactly-once lifecycle via `~Copyable` per [IMPL-064]:

- **`IO.Completion.Submission: ~Copyable`** — cross-thread publication envelope. Carries continuation + storage + cancellation flag. Enqueued to MPSC queue by client, consumed on dequeue by poll thread. Crosses threads via single-owner transfer through the MPSC queue (same pattern as `IO.Completion.Poll.Context`). Avoid `@unchecked Sendable` — the MPSC queue handles the thread crossing; `Submission` itself does not need to be marked `Sendable`. If the queue's generic constraint requires `Sendable`, use `sending` at the enqueue boundary instead.

- **`IO.Completion.Entry: ~Copyable`** — poll-thread-owned authoritative in-flight record. Created from `Submission` on dequeue. Never shared after creation. Not `Sendable` — confined to poll thread.

The ownership boundary is explicit: `Submission` is a publication envelope that crosses threads. `Entry` is an authoritative record that never leaves the poll thread. A `consuming` dequeue produces an `Entry`; a `consuming func resolve()` enforces single terminal commit at compile time.

### The new poll loop

```
while !shutdown {
    dequeue submissions from MPSC queue
      - if cancelled: resolve as cancelled, resume, skip driver (never registered)
      - else: create Entry, submit to driver, add to table
    check registered entries for cancellation
      - if cancelled and not yet completed: resolve as cancelled, resume, remove
    poll(deadline) for kernel completions
    match completions to entries
      - resolve(with: completion), remove from table
}
// shutdown: freeze acceptance (shutdownFlag.set()), resolve all remaining entries, push exit signal
```

**`resolve()` is the single terminal commit point.** A `consuming` method on `Entry` that stores the outcome in `storage.completion` and calls `continuation.resume()`. The `consuming` annotation enforces at compile time that an entry cannot be resolved twice. This encodes the terminal law as a compiler constraint, not a comment.

```swift
extension IO.Completion.Entry {
    consuming func resolve(with outcome: IO.Completion.Outcome) {
        storage.completion = IO.Completion.Event(
            id: id, kind: kind, outcome: outcome
        )
        continuation.resume()
    }
}
```

Direct `CheckedContinuation<Void, Never>.resume()` from the poll thread in all cases. Resume enqueues the task to its executor — does not run inline on the poll thread.

**Note on `resume()` safety:** Swift's current runtime enqueues the suspended task back onto its executor when `resume()` is called from a non-executor thread. This is the expected and tested behavior but is not formally guaranteed by a Swift Evolution proposal. Accepted as a pragmatic reliance on stable runtime behavior, consistent with how `resume()` is used throughout the ecosystem (including Apple's HTTP API proposal).

### Cancellation timing analysis

| Timing | Behavior |
|--------|----------|
| Cancel before enqueue | Flag set before entry reaches queue. Poll thread dequeues, sees flag, resolves as cancelled. Never submitted to driver. |
| Cancel after enqueue, before dequeue | Same — poll thread sees flag on dequeue. |
| Cancel after registration | Poll thread wakes via `wakeup.wake()`, checks cancelled entries, resolves. |
| Cancel after completion | Flag set but nobody reads it. Continuation already resumed. No effect. |
| Completion arrives for cancelled entry | Completion committed first (terminal law). Cancellation intent ignored. |

No race in any case. The atomic flag is write-once. The poll thread is the only decision-maker.

### Shutdown sequence

1. **Freeze acceptance:** `shutdownFlag.set()` — atomic, visible to all threads. New `submit()` calls fast-reject with lifecycle error.
2. **Wake poll thread:** `wakeup.wake()` — interrupts blocking `driver.poll()`.
3. **Poll thread resolves all entries:** iterates table, stores cancellation events, calls `resolve()` on each. Bounded by known in-flight entries.
4. **Poll thread closes driver handle and pushes exit signal:** `exit.push(())`.
5. **Client awaits exit:** `await exit.next()` — non-blocking, suspends until poll thread exits.

The herd of `resume()` calls during step 3 is acceptable: each enqueues a task (doesn't run inline), the burst is finite and proportional to outstanding work, and those tasks were already suspended awaiting resolution.

### Kernel cancellation: explicitly out of scope

Cancellation means "stop waiting for this operation," not "abort the kernel operation."

- Pre-registration cancellation: skip driver submission, resolve as cancelled.
- Post-registration cancellation: mark intent, poll thread resolves as cancelled if no completion committed yet. The kernel operation may still complete — the completion is a late arrival and is dropped.
- No `io_uring_prep_cancel` or IOCP cancel in phase 1.
- Driver-specific kernel cancellation can be layered later as optimization, not correctness primitive.

### Test synchronization

The current actor-based test hooks (`_waitUntilRecorded`, `_waitUntilDrained`) rely on `await` for clean synchronization. Without the actor, this mechanism must be replaced.

**Mechanism:** The poll thread pushes lifecycle events to a test-only `Async.Bridge<Void>` when test hooks are installed. Tests `await` the bridge for specific state transitions. This reuses the existing `Async.Bridge` primitive, provides clean async synchronization without busy-waiting, and is only active in test builds (zero overhead in production).

Concrete test probes:
- `_onEntryRegistered: Async.Bridge<IO.Completion.ID>?` — pushed when an entry transitions to `registered`
- `_onEntryResolved: Async.Bridge<IO.Completion.ID>?` — pushed when an entry is resolved
- `_drainedEventCount: Atomic<UInt64>` — lock-free counter readable from any thread

### `Operation.Storage` ownership transfer

`IO.Completion.Operation.Storage` is a `final class` shared between the poll thread and the client. The poll thread writes `storage.completion` (storing the event), then calls `continuation.resume()`. The client reads `storage.completion` after `resume()` wakes it.

The `resume()` call provides a happens-before relationship: the poll thread's write to `storage.completion` is visible to the client's read after the continuation resumes. This is safe without actor isolation because `resume()` is a synchronization point. The `@unchecked Sendable` safety comment on `Storage` must be updated to document this new invariant.

### Queue initialization: single MPSC queue

The current architecture has two queues: `Submit.Queue` (client -> Runtime actor, carries waiter + storage) and `Submission.Queue` (client -> poll thread, carries operation storage for direct driver submission).

With the actor removed, these collapse into a single MPSC queue carrying `IO.Completion.Submission` (which includes continuation + storage + cancellation flag). The poll thread dequeues, creates an `Entry`, and submits to the driver — all in one place.

## Findings

### Finding 1: The actor was a second serialization domain, not a simplification

The Runtime actor did not simplify the Completion Queue. It created a split-ownership topology that required a bridge, a drain loop, and a six-state Waiter to coordinate. The hang bug was a direct consequence of this topology — the actor's only input (the bridge) had no path for cancellation notifications.

### Finding 2: The poll thread is the natural owner

The poll thread already serializes all kernel interactions. Making it the sole lifecycle authority eliminates the notification gap, the bridge, the drain loop, and most of the Waiter complexity. The cross-thread primitive reduces from a six-state atomic machine to one boolean flag in a reference-type wrapper.

### Finding 3: This is subsystem-specific, not universal

The Events Selector has legitimate fan-out that justifies its actor. The principle is: **place ownership at the unique serialization point that already exists in the subsystem.** For Completions, that's the poll thread. For Events, that's the actor.

### Finding 4: Kernel cancellation is orthogonal

Cancellation means "stop waiting for this operation," not "abort the kernel operation." Kernel-level cancel (io_uring_prep_cancel, IOCP cancel) can be layered later as a driver-specific optimization.

### Finding 5: ~Copyable enforces the lifecycle at compile time

Making `Submission` and `Entry` `~Copyable` with `consuming` transitions encodes the terminal law as a compiler constraint. Double-resolution becomes a compile error, not a runtime precondition. This follows Apple's HTTP API proposal pattern where every I/O envelope type is `~Copyable`.

## What gets removed

- `IO.Completion.Queue.Runtime` (actor)
- `IO.Completion.Bridge` + `IO.Completion.Bridge+Methods`
- `IO.Completion.Waiter` (class with 6-state atomic machine)
- `IO.Completion.Waiter.State`
- `IO.Completion.Waiter.Resume`
- `IO.Completion.Waiter.Take`
- `IO.Completion.Submit.Queue` (merged into single MPSC queue)
- `IO.Completion.Submit.Entry`
- Drain loop, `drainCancelledEntries()`, `processSubmitQueue()` on actor

## What gets added

- `IO.Completion.Submission: ~Copyable` — cross-thread envelope, one file (avoid `@unchecked Sendable`; use `sending` at enqueue boundary)
- `IO.Completion.Entry: ~Copyable` — poll-thread-owned record with `consuming func resolve()`, one file
- `IO.Completion.Cancellation.Flag` — `final class` wrapping `Atomic<Bool>`, one file
- Integrated poll loop with dequeue, cancellation check, driver submit, poll, completion matching, direct resume
- Test hooks: optional `Async.Bridge` probes + atomic counter

## What stays the same

- Public API: `Queue`, `submit()`, `shutdown()`, `Scope`
- Poll thread spawn/detach/exit signal pattern
- Wakeup channel for interrupting poll
- Shutdown flag for fast-reject
- `Operation.Storage` as shared class (ownership transfer via resume() happens-before)
- `Submission.Queue` for driver-level submissions (renamed from current usage)

## Broader audit

Completion Queue is the canonical example of ownership collapse. The same lens should be applied to IO Blocking:
- Where is the true serialization point?
- Which abstractions own lifecycle vs. relay it?
- Are we using structured concurrency to model coordination, or to paper over domain mismatch?

## References

- Full discussion transcript: `/tmp/swift-io-concurrency-redesign-transcript.md`
- Critical review: conducted post-convergence, gaps integrated into v2.0
- Apple HTTP API proposal: `/Users/coen/Developer/apple/swift-http-api-proposal` — patterns for `~Copyable` I/O types
- Current implementation: `Sources/IO Completions/`
- Poll thread exit signal: `Research/perfect-lifecycle-design.md`
- Prior lifecycle research: `Research/executor-lifecycle-architecture.md`
