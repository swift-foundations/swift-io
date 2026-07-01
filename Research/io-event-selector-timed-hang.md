# IO.Event.Selector Hang Under Repeated .timed() Iterations

<!--
---
version: 2.0.0
last_updated: 2026-03-24
status: RESOLVED — benchmark hang fixed; infrastructure hardening pending
---
-->

## Resolution Summary

**Root cause**: Test bug, not selector infrastructure bug. `makeNonBlockingSocketPair()` set BOTH sockets to `O_NONBLOCK`, but the detached echo/reader/writer tasks use blocking-style `read()`/`write()`. The detached task races against the Channel's first write and fails with `EWOULDBLOCK`, killing the echo while `channel.read()` waits forever for a response that will never come.

**Fix committed**: `18d1844` — Renamed to `makeSocketPairForChannel()`, only sets sockets.0 (Channel side) to non-blocking. Re-enabled all 4 benchmarks. Added 4 regression tests.

**Selector infrastructure is correct.** Register/deregister cycles, fd recycling, channel echo across iterations, concurrent access — all verified clean. No state pollution, no permit leaks under correct usage, no kqueue filter corruption.

**However**, the investigation surfaced 5 infrastructure hardening items ranked below.

---

## Hypothesis Disposition

| Hypothesis | Verdict | Evidence |
|-----------|---------|----------|
| H1: Registration leak | **Ruled out** | 5 iterations × 100 register/deregister cycles pass in 0.057s. Fd recycling test verifies events route to new registrations. |
| H2: Continuation leak | **Ruled out** | Channel echo across 3 iterations × 100 round-trips completes cleanly. Waiter state machine correctly drains. |
| H3: Token lifecycle mismatch | **Ruled out** | ~Copyable tokens consumed correctly. Deregister cleans up all state (registrations, waiters, permits, deadline generation). |
| H4: Shared singleton pollution | **Ruled out** | 4 concurrent tasks × 25 register/deregister cycles on shared selector — no cross-talk. |
| H5: Task.detached never executes | **Confirmed (modified)** | Detached tasks DO execute, but fail immediately with `EWOULDBLOCK` on the non-blocking raw fd. The cooperative pool is idle because the detached tasks already threw and exited. |

---

## Infrastructure Hardening — Ranked by Severity

The investigation surfaced 5 issues in the IO.Event infrastructure. None caused the benchmark hang, but all are latent risks for production use. Ranked most dangerous first.

### 1. Channel drop without close() leaks fd + kqueue filter — CRITICAL

**What**: `IO.Event.Channel` is `~Copyable` with a `consuming func close()`. If `close()` is never reached (a prior `try await` throws), the channel is dropped without deregistering. The kqueue filter persists for a descriptor the OS may recycle. The fd itself leaks (never closed).

**Where**: `IO.Event.Channel.swift` — no `deinit`.

**Impact**: On a long-running server, each error path that skips `close()` leaks one fd. Silent accumulation until `EMFILE` — process can't accept new connections. No log, no assertion, no crash.

**Fix direction**: Add `deinit` to Channel that either:
- (a) `preconditionFailure("Channel dropped without close()")` in debug builds, or
- (b) Best-effort fire-and-forget deregister + close (requires careful design since deinit can't be async)

Option (a) is safer for "timeless infrastructure" — it makes the contract unambiguous. Callers MUST close. A `defer { try? await channel.close() }` pattern can be documented.

**Files**:
- `swift-io/Sources/IO Events/IO.Event.Channel.swift`

---

### 2. Wakeup channel trigger silently swallows errors — HIGH

**What**: The wakeup channel uses `try?` to trigger EVFILT_USER:
```swift
_ = try? Kernel.Kqueue.register(kq, events: [triggerEv])
```
If this ever fails (bad fd, resource exhaustion, kernel error), the poll thread never wakes from `kevent()`. Every subsequent selector operation (register, deregister, arm) suspends forever waiting for a reply.

**Where**: `IO.Event.Queue.Operations.swift:444` (kqueue wakeup channel factory).

**Impact**: Total selector hang. One transient kernel error kills the entire I/O subsystem. Zero diagnostic output.

**Fix direction**: Replace `try?` with `try` and propagate the error, or at minimum log/assert on failure. The wakeup is on a hot path (called on every register/deregister/arm), so the failure handling must be cheap. A `preconditionFailure` in debug + best-effort retry in release may be appropriate.

**Files**:
- `swift-io/Sources/IO Events/IO.Event.Queue.Operations.swift` (Darwin)
- `swift-io/Sources/IO Events/IO.Event.Poll.Operations.swift` (Linux — check if same pattern)

---

### 3. Poll loop exits permanently on any driver.poll() error — HIGH

**What**: The poll loop catches `driver.poll()` errors with:
```swift
} catch {
    eventBridge.finish()
    replyBridge.finish()
    break
}
```
A single `kevent()` error (ENOMEM, EBADF from kernel bug) breaks the loop permanently. The bridges are finished. The event loop and reply loop tasks exit. The selector actor still accepts calls but never processes them.

**Where**: `IO.Event.Poll.Loop.swift:118-122`.

**Impact**: Total selector death, indistinguishable from a hang. The selector looks alive (actor responds to method calls) but all operations suspend forever.

**Fix direction**: Distinguish transient errors (retry after backoff) from fatal errors (break). EINTR is already handled. ENOMEM and signal interruption should retry. EBADF is fatal (kqueue fd is gone). Add logging on break so the failure is diagnosable.

**Files**:
- `swift-io/Sources/IO Events/IO.Event.Poll.Loop.swift`

---

### 4. Channel.read()/write() has no deadline or escape hatch — MEDIUM

**What**: If the peer is alive but stops sending (application deadlock, slow loris, stuck process), `channel.read()` suspends forever. There is no built-in timeout. Task cancellation works (the waiter cancellation handler fires), but callers must implement their own cancellation logic.

**Where**: `IO.Event.Channel.swift:139` (read), `IO.Event.Channel.swift:212` (write).

**Impact**: Per-task permanent hang. Requires every caller to independently solve the timeout problem. One missed timeout = one permanently stuck task.

**Fix direction**: The `arm()` method already supports a `deadline` parameter. Channel.read()/write() could accept an optional `deadline: IO.Event.Deadline?` parameter. When provided, arm is called with the deadline. On expiry, the waiter is resumed with `.timeout`. This is additive — no breaking change.

**Files**:
- `swift-io/Sources/IO Events/IO.Event.Channel.swift`

---

### 5. Stale permit after deregister — LOW

**What**: If an event is processed by the selector's event loop AFTER `deregister()` cleans up permits but BEFORE the kqueue `EV_DELETE` takes effect, the event creates a new permit for the deregistered ID. This permit is never cleaned up (no future deregister will run for that ID).

**Where**: `IO.Event.Selector.swift:948-986` (`processEvent`) and `IO.Event.Selector.swift:740-781` (`deregister`).

**Impact**: Slow memory leak. Each stale entry is one `(Permit.Key, IO.Event.Flags)` — ~32 bytes. Only matters for very long-running processes with many register/deregister cycles.

**Fix direction**: In `processEvent()`, check `registrations[event.id]` before storing a permit. If the ID is not in `registrations`, drop the event. This is a one-line guard.

**Files**:
- `swift-io/Sources/IO Events/IO.Event.Selector.swift`

---

## Handoff Instructions for Hardening

**Goal**: Fix items 1–3 (CRITICAL + HIGH). Items 4–5 are desirable but lower priority.

**Invoke**: `/implementation` and `/platform` for code changes. `/testing` for each fix.

**Effort**: Maximum. These are silent-failure-at-3-AM-class bugs.

**Approach**: Each item is independent. Can be done in any order, committed separately. Item 1 (Channel deinit) is the highest-value fix — it catches the most common failure pattern (error path skips close).

**Constraint**: Item 1 requires careful design because `deinit` cannot be `async`. The deregister path is async (sends request to poll thread, awaits reply). Options:
- (a) Debug-only `preconditionFailure` (no deregister, just fail loud)
- (b) Fire-and-forget deregister (enqueue request, don't await reply, close fd synchronously)
- (c) Both: preconditionFailure in debug, fire-and-forget in release

Option (c) is the principled choice for timeless infrastructure.

---

## Regression Tests (Committed)

Located in `swift-io/Tests/IO Events Tests/IO.Event.Selector.Iteration.Tests.swift`:

1. **`register deregister 5 iterations × 100 cycles`** — Validates selector state across repeated register/deregister on recycled fds.
2. **`fd recycling after close creates fresh registration`** — Creates pipe, registers, arms, verifies event, deregisters, closes, repeats 10×. Confirms events route to new registrations after fd recycling.
3. **`channel echo 3 iterations × 100 round-trips reused selector`** — Full echo with socket pairs across 3 iterations on the same selector. Validates no state pollution.
4. **`concurrent register deregister from multiple tasks`** — 4 concurrent tasks × 25 register/deregister cycles. Validates no cross-talk.

---

## Original Investigation Record

### The 4 Previously-Disabled Tests

```
Channel.Test.Performance.`echo 1000 round-trips 64B messages`
Channel.Test.Performance.`read throughput 1MB`
Channel.Test.Performance.`write throughput 1MB`
Selector.Test.Performance.`register deregister cycle on pipe`
```

All 4 re-enabled in commit `18d1844`.

### Key Diagnostic Evidence

```
[DIAG] iter=0 trip=0 writing
[DIAG] iter=0 trip=0 wrote 64B, reading
[DIAG] echoTask read error trip=0 totalRead=0: blocking: operation would block
```

The echoTask fails on trip 0 with `EWOULDBLOCK`. It races against `channel.write()` — the detached task starts on the cooperative pool and calls `read()` on the non-blocking raw fd before the Channel side has written any data. The Channel side then suspends in `channel.read()` waiting for an echo response that will never come (echoTask is dead).

### Files Modified in Fix Commit

- `Benchmarks/io-bench/IO Performance Tests/Channel.swift` — Renamed helper, removed `.disabled()` from 3 tests
- `Benchmarks/io-bench/IO Performance Tests/Selector.swift` — Removed `.disabled()` from 1 test
- `Tests/IO Events Tests/IO.Event.Selector.Iteration.Tests.swift` — New: 4 regression tests

### References

- Thread sample from hanging process: 40 threads, 34 condvar, 3 kqueue, 3 GCD idle
- Cooperative pool is idle when hang occurs — detached tasks already threw and exited
- `swift-io/Research/io-bench-process-hang.md` — parent research document
