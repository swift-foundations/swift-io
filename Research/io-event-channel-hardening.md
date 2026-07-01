# IO.Event.Channel Infrastructure Hardening

<!--
---
version: 1.0.0
last_updated: 2026-03-24
status: READY
---
-->

## Handoff Instructions

**Goal**: Fix the 3 highest-severity infrastructure issues in the IO.Event subsystem, identified during the selector hang investigation (see `io-event-selector-timed-hang.md` for full context).

**Invoke**: `/implementation` and `/platform` for code changes. `/testing` for each fix.

**Effort**: Maximum. These are silent-failure-at-3-AM-class bugs in timeless infrastructure.

**Approach**: Three independent fixes, each committed separately with tests. Do them in order — item 1 is highest value.

---

## Background

The IO.Event.Selector was verified correct — register/deregister cycles, fd recycling, channel echo across iterations, concurrent access all work. But the investigation surfaced infrastructure-level issues where silent failures accumulate until the process is unrecoverable. None cause the original benchmark hang, but all are latent production risks.

Read `io-event-selector-timed-hang.md` §"Infrastructure Hardening — Ranked by Severity" for the full analysis. This document is the execution plan.

---

## Item 1: Channel deinit — CRITICAL

**Problem**: `IO.Event.Channel` is `~Copyable` with `consuming func close()`. If any `try await` throws before `close()` is reached, the channel is dropped silently. The kqueue filter persists for a descriptor the OS may recycle. The fd leaks. On a server, this exhausts fds until `EMFILE`.

**File**: `swift-io/Sources/IO Events/IO.Event.Channel.swift`

**Design constraint**: `deinit` cannot be `async`. The deregister path is async (sends request to poll thread, awaits reply). So `deinit` cannot do a full deregister.

**Implementation**:

Add a `deinit` to `IO.Event.Channel` that:

1. In **debug builds**: `assertionFailure("IO.Event.Channel dropped without close() — call close() on all code paths")`. This makes the contract loud during development.

2. In **all builds**: Fire-and-forget cleanup:
   - Enqueue a `.deregister(id: id, replyID: nil)` directly to the selector's `registrationQueue` (no reply needed — fire-and-forget)
   - Call `wakeupChannel.wake()` to ensure the poll thread processes it
   - Call `try? Kernel.Close.close(descriptor)` to close the fd synchronously

   This requires Channel to store a reference to the `registrationQueue` and `wakeupChannel` (both are `Sendable`). Currently Channel stores `selector: Selector` — but accessing the selector's internal fields from deinit is not possible (actor isolation). So the Channel init must capture the queue and wakeup channel directly.

**Key decisions to make**:
- Channel currently stores `private let selector: Selector`. It will also need `private let registrationQueue: IO.Event.Registration.Queue` and `private let wakeupChannel: IO.Event.Wakeup.Channel` for deinit access. These are already Sendable — just pass them through from `wrap()`.
- The fire-and-forget deregister uses `replyID: nil` which is already supported by the poll loop's `processRequests` (it handles optional replyID on deregister).
- The `id` field on Channel is already stored as `private let id: ID`.

**Test**: Write a test that creates a Channel, does NOT call close(), lets it go out of scope, then verifies the fd was closed and a new registration on the same fd succeeds. Use `#expect(throws:)` in debug to verify the assertion fires.

---

## Item 2: Wakeup channel error handling — HIGH

**Problem**: The wakeup trigger uses `try?`:
```swift
_ = try? Kernel.Kqueue.register(kq, events: [triggerEv])
```
If this fails, the poll thread never wakes. Every subsequent selector operation hangs forever. Zero diagnostic output.

**Files**:
- `swift-io/Sources/IO Events/IO.Event.Queue.Operations.swift` (Darwin kqueue — line ~444)
- `swift-io/Sources/IO Events/IO.Event.Poll.Operations.swift` (Linux epoll — check for same pattern)
- `swift-io/Sources/IO Events/IO.Event.Wakeup.Channel.swift` (the Channel type itself)

**Implementation**:

The `IO.Event.Wakeup.Channel` is created as a closure:
```swift
return IO.Event.Wakeup.Channel {
    let triggerEv = ...
    _ = try? Kernel.Kqueue.register(kq, events: [triggerEv])
}
```

Change the closure to:
```swift
return IO.Event.Wakeup.Channel {
    let triggerEv = ...
    do {
        try Kernel.Kqueue.register(kq, events: [triggerEv])
    } catch {
        // Wakeup failure is unrecoverable — the poll thread will never process
        // pending requests. This indicates a corrupted kqueue fd or kernel error.
        assertionFailure("IO.Event.Wakeup.Channel: trigger failed: \(error)")
        // In release: retry once, then accept the loss.
        // The next operation that enqueues a request will also wake,
        // providing natural retry semantics.
    }
}
```

Check if `Wakeup.Channel.wake()` is the closure caller — if so, the error handling goes there. Read the Wakeup.Channel type to understand the exact call site.

Do the same audit for the epoll path (Linux) — `eventfd` signaling may have the same `try?` pattern.

**Test**: This is hard to test directly (can't easily force kevent to fail). At minimum, verify the wakeup channel works under stress: create a selector, do 10,000 register/deregister cycles rapidly, verify all complete. This exercises the wakeup path heavily.

---

## Item 3: Poll loop resilience — HIGH

**Problem**: The poll loop exits permanently on any `driver.poll()` error:
```swift
} catch {
    eventBridge.finish()
    replyBridge.finish()
    break
}
```
One transient error (ENOMEM, signal) kills the selector permanently. The actor still accepts calls but never processes them.

**File**: `swift-io/Sources/IO Events/IO.Event.Poll.Loop.swift` (lines ~118-122)

**Implementation**:

Replace the catch-all break with error classification:

```swift
} catch {
    switch error {
    case .platform(let code) where code.isTransient:
        // ENOMEM, EINTR (if it somehow reaches here) — retry after brief yield
        // sched_yield() or Thread.sleep(forTimeInterval: 0.001)
        continue
    default:
        // Fatal: EBADF (kqueue fd gone), unknown errors
        // Log the error for diagnostics before dying
        assertionFailure("IO.Event.Poll.Loop: fatal poll error: \(error)")
        eventBridge.finish()
        replyBridge.finish()
        break
    }
}
```

Define `isTransient` on `Kernel.Error.Code` (or inline the check) to cover:
- ENOMEM — transient memory pressure
- EINTR — should already be handled by the driver, but defense in depth
- EAGAIN — unlikely from kevent but safe to retry

Everything else (EBADF, EINVAL, EFAULT) is fatal — the kqueue fd is corrupt or gone.

**Test**: Hard to test the error path directly. The stress tests from Item 2 provide indirect coverage. Consider adding a test with the Fake driver that simulates a transient poll error and verifies the selector recovers.

---

## Build and Run

```bash
cd /Users/coen/Developer/swift-foundations/swift-io
swift build
swift test --filter "IO/Event"
```

## Commit Convention

One commit per item. Message format:
```
Add Channel.deinit for fd leak prevention on error paths

[description of what and why]
```
