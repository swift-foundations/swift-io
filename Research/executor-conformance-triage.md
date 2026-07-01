# Executor Conformance Triage

> Following inventory (`executor-conformance-inventory.md`): 3 conformances total,
> 2 non-`swift-executors` (`IO.Event.Loop`, `IO.Completion.Loop`). This triage
> evaluates whether each can/should extract to `swift-executors`, and how.
>
> Produced: 2026-04-15

## TL;DR

Both `IO.Event.Loop` and `IO.Completion.Loop` should **stay where they are
(Option D — keep duplication relative to `Kernel.Thread.Executor`)**.

The conformances look identical at the declaration line; the runtime semantics
diverge fundamentally. The IO loops are *poll-blocking integrated executors*:
the wait primitive is a kernel poll (`kqueue`/`epoll`/`io_uring`/IOCP), the
wake primitive is a kernel-level wakeup channel, and the shutdown is two-step
(halt-flag-then-join). `Kernel.Thread.Executor` is a *condvar-blocking job
dispatcher*: the wait primitive is a `pthread_cond_wait`, the wake is a
condvar broadcast, and shutdown is one-step (flip-flag-and-broadcast-then-join).
You cannot share a thread between a condvar-block and a poll-block; you cannot
share a wake mechanism between a condvar broadcast and an `eventfd` write.

A **load-bearing constraint** rules out Option A (compose-with-existing): if the
Loop holds an external `Kernel.Thread.Executor` and forwards `unownedExecutor`
to it, actor methods on `IO.Events.Actor` / `IO.Completions.Actor` would run
on the held executor's thread, but the Loop's `runLoop()` runs on its *own*
thread, and both threads access shared mutable state (`source`, `entries`,
`registrations`). That's a race the current architecture rules out by
construction (Loop *is* the executor → actor methods *are* the runLoop's thread).

A **narrow Option C** — extract a `PollingJobQueue` helper that absorbs the
job-queue + drain mechanics shared between the two IO loops (not between the
IO loops and `Kernel.Thread.Executor`) — is feasible and saves ~60 LOC across
the two IO loops. This is documented as an optional follow-up; it is not the
recommended path because the cost (new public type, new package dep on
`Executors` from two `IO` targets) is comparable to the savings.

## Reference: `Kernel.Thread.Executor` anatomy

(See `swift-foundations/swift-executors/Sources/Executors/Kernel.Thread.Executor.swift:76-236`.)

A serial executor backed by one dedicated OS thread.

| Aspect              | Mechanism                                                          |
|---------------------|--------------------------------------------------------------------|
| Job queue           | `Kernel.Thread.Executor.Job.Queue` — `Deque<UnownedJob>`, O(1) FIFO |
| Lock                | `Kernel.Thread.Synchronization<1>` — Mutex + 1 condvar             |
| Thread spawn        | `Kernel.Thread.trap(Ownership.Transfer.Retained(self)) { runLoop() }` |
| Wait primitive      | `sync.wait()` on the (sole) condvar — **condvar-blocking**         |
| Wake primitive      | `sync.signal()` (enqueue path), `sync.broadcast()` (shutdown path) |
| Run-loop body       | `while true { dequeue-one-under-lock; runJob() }`                  |
| `enqueue(_:)` shape | `withLock { append; check isRunning }; if alive then signal else runInline` |
| Shutdown            | `withLock { isRunning = false }; broadcast(); handle.join()` — one step |
| Mode toggle         | `Mode.serial` / `.task` — selects which `runSynchronously(on:)` overload |
| Domain coupling     | None — pure executor. Owns thread + queue + condvar; nothing else. |

The condvar-blocking model is the load-bearing characteristic. The wake
mechanism (condvar broadcast) is the ONLY way to interrupt the run loop.

---

## IO.Event.Loop — triage

(See `swift-foundations/swift-io/Sources/IO Events/IO.Event.Loop.swift:41-340`.)

### Structural comparison

| Aspect              | `Kernel.Thread.Executor`                          | `IO.Event.Loop`                                                                 | Same? |
|---------------------|---------------------------------------------------|---------------------------------------------------------------------------------|-------|
| Job queue type      | `Job.Queue` (Deque-backed, O(1) FIFO)             | `ContiguousArray<UnownedJob>` + swap-with-`drainBuffer` (batch-drain)           | **N** |
| Lock type           | `Kernel.Thread.Synchronization<1>` (used as condvar **and** mutex) | `Kernel.Thread.Synchronization<1>` (used **only** as mutex; condvar unused)     | partial — same type, only mutex API used |
| Thread spawn        | `Kernel.Thread.trap(Retained(self)) { runLoop() }` | `Kernel.Thread.trap(Retained(self)) { runLoop() }`                              | **Y** |
| Wait primitive      | `sync.wait()` (condvar)                           | `source.poll(deadline: nil, into: &eventBuffer)` (`kevent`/`epoll_wait`)         | **N — fundamentally different** |
| Wake primitive      | `sync.signal()` / `sync.broadcast()`              | `wakeup.wake()` — `EVFILT_USER` (kqueue) / `eventfd` write (epoll) / `PostQueuedCompletionStatus` (IOCP) | **N — fundamentally different** |
| Run-loop body       | `dequeue-one-under-lock → runJob`                 | `drainJobs (batch) → check shouldHalt → poll → dispatchEvents`                  | **N** |
| `enqueue(_:)`       | `append-under-lock; if alive { signal } else { runInline }` | `append-under-lock; if alive { wakeup.wake() } else { runInline }`              | **structurally Y; mechanism N** |
| `unownedExecutor`   | `UnownedSerialExecutor(ordinary: self)`           | `UnownedSerialExecutor(ordinary: self)`                                          | **Y** |
| Shutdown shape      | One-step: `withLock { isRunning = false }; broadcast(); join()` | Two-step: actor enqueues a job that sets `shouldHalt = true`; later, `loop.shutdown()` calls `handle.join()` only | **N — fundamentally different** |
| Domain state        | None                                              | `source: Kernel.Event.Source?`, `registrations: [IO.Event.ID: Registration]`, `eventBuffer`, `shouldHalt`, `wakeup` | N/A — domain |
| Resource lifecycle  | Just a thread to join                             | Source must outlive the thread; consumed in `deinit` (single-close invariant)   | N/A — domain |

### Quantification

Per-line accounting of the `Loop` class body (excluding doc comments):

| Region                                           | LOC | Classification     |
|--------------------------------------------------|----:|--------------------|
| Stored properties — `sync`, `jobs`, `drainBuffer`, `isRunning`, `threadHandle`, `wakeup` | 6 | executor-generic |
| `init`'s thread-spawn block                      |  5  | executor-generic   |
| `enqueue(UnownedJob)`                            | 12  | executor-generic   |
| `asUnownedSerialExecutor()`                      |  3  | executor-generic   |
| `enqueue(consuming ExecutorJob)`                 |  3  | executor-generic   |
| `drainJobs()`                                    | 12  | executor-generic   |
| `shutdown()`                                     | 14  | executor-generic   |
| Stored properties — `source`, `maxEventsPerPoll`, `shouldHalt`, `registrations` | 5 | domain |
| `init`'s wakeup-extract + source storage         |  5  | domain             |
| `deinit`'s thread-detach + source consume        | 16  | domain             |
| `withSource` (×2 overloads)                      | 12  | domain             |
| `runLoop()` poll/dispatch (excl. drainJobs call) | 30  | domain             |
| `dispatchEvents`                                 | 16  | domain             |
| `shutdownCleanup`                                |  6  | mixed (drain + flip flag — half generic, half domain) |
| `fatalCleanup`                                   | 14  | domain             |

- **Total LOC (class body, sans docs):** ~160
- **Executor-generic overlap:** ~55 (~34%)
- **Domain-specific:** ~100 (~62%)
- **Mixed:** ~6 (~4%)
- **Assessment:** *substantive* — the executor-generic share (34%) is real but
  the executor-generic code that *could* share with `Kernel.Thread.Executor`
  drops to <15% once you exclude the parts where the *same surface* (`enqueue`,
  `drainJobs`, `shutdown`) is implemented with a *different mechanism* (poll
  vs condvar, kernel-wakeup vs broadcast, two-step vs one-step shutdown).

### Load-bearing divergence

The IO Event run loop is **`while !shouldHalt { drainJobs(); poll(blocking); dispatchEvents() }`**.

The Kernel Thread Executor run loop is **`while !shutdown { awaitJobUnderLock(); runJob() }`**.

These are not the same shape with different bodies. They have different *wait primitives*:

- `Kernel.Thread.Executor` waits inside the lock, on the condvar, with the queue empty.
  When `enqueue` arrives, it signals the condvar; the executor wakes, dequeues, runs.
- `IO.Event.Loop` waits OUTSIDE the lock, in `kevent`/`epoll_wait`, with the queue
  potentially non-empty (the `enqueue` path's `wakeup.wake()` ensures the next
  poll iteration returns even if no real I/O event has arrived). When the poll
  returns, the loop drains the queue and dispatches events.

You cannot extend `Kernel.Thread.Executor`'s run loop with a "wait on
either condvar OR poll" primitive — that's not how condvars compose with
file-descriptor blocking. Linux's `signalfd` + `epoll` could let you fold
condvar wakeups into an `epoll_wait`, but that's a substantial rewrite of
`Kernel.Thread.Executor` (giving up its condvar semantics for an fd-based
wakeup) for no portability or perf benefit.

The shutdown-shape divergence is also load-bearing. `Kernel.Thread.Executor`
can shut itself down via `broadcast() → wait() returns → check isRunning →
exit run loop`. `IO.Event.Loop` cannot — its run loop is parked in a kernel
poll, not a condvar wait. The two-step shutdown (actor sets `shouldHalt` from
inside an enqueued job, so the flag flip happens on the executor thread; then
caller joins) is the only way to cleanly halt a poll-blocked loop without
race.

### Recommendation: **Option D — keep duplication.**

`IO.Event.Loop` cannot reasonably extract to `swift-executors` as a consumer
of `Kernel.Thread.Executor`. The wait primitive, wake primitive, and shutdown
shape are mutually exclusive between condvar-blocking and poll-blocking
executors. The structural similarity at the conformance line (`SerialExecutor +
TaskExecutor + @unchecked Sendable`) is superficial.

### Cost (of the recommended Option D)

- LOC changed in `swift-executors`: **0**
- LOC changed in `swift-io`: **0**
- Public API changes: **none**
- Performance implications: **none**

---

## IO.Completion.Loop — triage

(See `swift-foundations/swift-io/Sources/IO Completions/IO.Completion.Loop.swift:44-361`.)

### Structural comparison

| Aspect              | `Kernel.Thread.Executor`                          | `IO.Completion.Loop`                                                                 | Same? |
|---------------------|---------------------------------------------------|--------------------------------------------------------------------------------------|-------|
| Job queue type      | `Job.Queue` (Deque-backed)                        | `ContiguousArray<UnownedJob>` + swap-with-`drainBuffer`                              | **N** |
| Lock type           | `Kernel.Thread.Synchronization<1>` (mutex + condvar) | `Kernel.Thread.Synchronization<1>` (mutex only)                                      | partial |
| Thread spawn        | `Kernel.Thread.trap(Retained(self)) { runLoop() }` | `Kernel.Thread.trap(Retained(self)) { runLoop() }`                                   | **Y** |
| Wait primitive      | `sync.wait()` (condvar)                           | `driver.poll(handle, deadline: nil, into: &eventBuffer)` (io_uring `io_uring_enter` / IOCP `GetQueuedCompletionStatusEx`) | **N — fundamentally different** |
| Wake primitive      | `sync.signal()` / `sync.broadcast()`              | `wakeup.wake()` — `eventfd` / `IORING_OP_NOP+IOSQE_IO_DRAIN` / `PostQueuedCompletionStatus` | **N — fundamentally different** |
| Run-loop body       | `dequeue-one-under-lock → runJob`                 | `drainJobs → check halt → checkCancellations → flush → poll → dispatchCQEs`          | **N** |
| `enqueue(_:)`       | `append-under-lock; signal`                       | `append-under-lock; wakeup.wake()`                                                    | **structurally Y; mechanism N** |
| `unownedExecutor`   | `UnownedSerialExecutor(ordinary: self)`           | `UnownedSerialExecutor(ordinary: self)`                                              | **Y** |
| Shutdown shape      | One-step (broadcast + join)                       | Two-step (actor enqueues a job that calls `requestHalt()`; caller calls `loop.shutdown()`) | **N** |
| Domain state        | None                                              | `driver: IO.Completion.Driver`, `handle: IO.Completion.Driver.Handle?`, `entries: [IO.Completion.ID: IO.Completion.Entry]`, `eventBuffer`, `shouldHalt`, `wakeup` | N/A |
| Resource lifecycle  | Thread join only                                  | Driver handle must outlive the thread; consumed in `deinit` via `driver.close(consume h)` (single-close invariant). Entries table must drain on shutdown (resolve as cancelled). | N/A |
| Cancellation        | N/A                                               | Multi-CQE handshake (cancellation flag on entry; `IORING_OP_ASYNC_CANCEL` submission via `IO.Completions.Actor.awaitOperation`) | N/A |

### Quantification

| Region                                           | LOC | Classification     |
|--------------------------------------------------|----:|--------------------|
| Stored properties — `sync`, `jobs`, `drainBuffer`, `isRunning`, `threadHandle`, `wakeup` | 6 | executor-generic |
| `init`'s thread-spawn block                      |  5  | executor-generic   |
| `enqueue(UnownedJob)`                            | 12  | executor-generic   |
| `asUnownedSerialExecutor()`                      |  3  | executor-generic   |
| `enqueue(consuming ExecutorJob)`                 |  3  | executor-generic   |
| `drainJobs()`                                    | 12  | executor-generic   |
| `shutdown()`                                     | 14  | executor-generic   |
| Stored properties — `driver`, `handle`, `entries`, `eventBuffer`, `shouldHalt` | 5 | domain |
| `init`'s driver create + wakeup setup            | 14  | domain             |
| `deinit`'s thread-detach + handle consume        | 16  | domain             |
| `submit`                                         | 10  | domain             |
| `requestHalt`                                    |  3  | domain             |
| `runLoop()` poll / flush / dispatchCQEs (excl. drainJobs + checkCancellations calls) | 35 | domain |
| `checkCancellations`                             | 13  | domain             |
| `shutdownCleanup` driver/entries cleanup         | 21  | mostly domain      |

- **Total LOC (class body, sans docs):** ~170
- **Executor-generic overlap:** ~55 (~32%)
- **Domain-specific:** ~115 (~68%)
- **Assessment:** *substantive* — same shape as Event.Loop. Net executor-generic
  share that *could* share with `Kernel.Thread.Executor` is again <15% once you
  exclude same-surface-different-mechanism code.

### Load-bearing divergence

Same as `IO.Event.Loop`: the run loop is poll-blocking, not condvar-blocking.
The wake primitive is a kernel-level wakeup channel, not a condvar broadcast.
The shutdown is two-step.

Additionally, `IO.Completion.Loop` has *more* per-iteration work than
`IO.Event.Loop`: `checkCancellations` (resolve any entries whose flag was set)
and `flush` (push pending SQEs to the kernel before polling) phases. This
makes the run loop body even further from `Kernel.Thread.Executor`'s shape.

### Recommendation: **Option D — keep duplication.**

Same reasoning as `IO.Event.Loop`. The poll-blocking model is incompatible
with `Kernel.Thread.Executor`'s condvar-blocking model.

### Cost (of the recommended Option D)

- LOC changed in `swift-executors`: **0**
- LOC changed in `swift-io`: **0**
- Public API changes: **none**
- Performance implications: **none**

---

## Why not Option A (compose-with-existing) — load-bearing breakage

> Flagged prominently per task spec: this is the "ideal goal collides with
> reality" finding.

Option A as stated would have `IO.Event.Loop` hold a `Kernel.Thread.Executor`
as a stored property; delegate `enqueue(_:)` to it; forward `unownedExecutor`
to the held executor.

**This would break the actor isolation invariant the loops rely on.**

Today, `IO.Events.Actor` declares `nonisolated var unownedExecutor:
UnownedSerialExecutor { unsafe executor.asUnownedSerialExecutor() }` where
`executor` is `IO.Event.Loop`. Actor methods marked `func ...` therefore run
on the Loop's thread (the one running `runLoop()`). These methods access
`executor.withSource { ... }` and `executor.registrations[...]`, which are
**directly mutating Loop state**. This is race-free because the Loop *is* the
executor — the actor methods and `runLoop()` execute on the same OS thread.

Under Option A, the actor would pin to the held `Kernel.Thread.Executor`'s
identity. The KTE owns its own thread. The Loop's `runLoop()` runs on the
Loop's thread. Now actor methods (running on KTE's thread) mutate `source` /
`registrations` while `runLoop()` (on Loop's thread) reads them in
`source.poll(...)` and `dispatchEvents(...)`. **Data race.**

The only way to fix the race under Option A would be to merge the two threads
— at which point you don't have two executors anymore, and you've effectively
re-derived the current architecture (Loop *is* the executor; one thread runs
both job dispatch and poll).

Same analysis applies to `IO.Completion.Loop` and its `entries` table.

---

## Why not Option B (inheritance) — Swift mechanics

Briefly: `SerialExecutor` requires `final class` (or struct/actor) for the
identity guarantees, and `@unchecked Sendable` doesn't compose cleanly with
inheritance. Even if one made it work via abstract base + open methods, the
divergent run-loop bodies (condvar wait vs poll) would force template-method
patterns that are uglier than today's duplication. Already-declined pattern.

---

## Optional follow-up (Option C, narrow): consolidate the IO loops with each other

**Not the recommended action** — flagged for the user's awareness.

The two IO loops (`IO.Event.Loop` and `IO.Completion.Loop`) duplicate ~55 LOC
of executor-generic code each, with virtually no functional divergence
between them on the executor-generic surface. Both:

- use `ContiguousArray<UnownedJob>` + swap-with-`drainBuffer`
- protect the queue with `Kernel.Thread.Synchronization<1>` used as mutex-only
- spawn one OS thread via `Kernel.Thread.trap(Retained(self)) { runLoop() }`
- wake a poll via an injected `wake` closure
- shut down via `shouldHalt` flag set from an enqueued job, then `handle.join()`

A `Kernel.Thread.PollingJobQueue` (or similar) helper in `swift-executors`
that absorbs:

```swift
public final class PollingJobQueue: @unchecked Sendable {
    private let sync: Kernel.Thread.Synchronization<1>
    private var jobs: ContiguousArray<UnownedJob> = []
    private var drainBuffer: ContiguousArray<UnownedJob> = []
    private var isRunning: Bool = true
    private let wake: @Sendable () -> Void

    public init(wake: @escaping @Sendable () -> Void) { /* … */ }

    /// Returns the inline-fallback job if the queue has been shut down.
    public func enqueue(_ job: UnownedJob) -> UnownedJob? { /* withLock { … } */ }

    /// Drains all queued jobs by calling `runJob` for each. Caller passes
    /// the executor identity to use via the closure (preserving the load-
    /// bearing identity invariant: the Loop conforms; the helper does not).
    public func drain(_ runJob: (UnownedJob) -> Void) { /* swap; iterate */ }

    public func markShutdown() { /* withLock { isRunning = false } */ }
}
```

would reduce per-IO-loop boilerplate by ~30 LOC and concentrate the
queue/lock/drain pattern in one place. The Loop *itself* keeps its
`SerialExecutor + TaskExecutor` conformance (preserving the actor-pinning
identity invariant); only the queue mechanics move.

### Cost of optional Option C

- LOC added in `swift-executors`: ~50–60 (one new public type + tests)
- LOC removed in `swift-io`: ~60 across the two IO loops
- Net LOC change: roughly break-even
- Public API: new type in `swift-executors`. No breaking change to `IO.Event.Loop`
  or `IO.Completion.Loop` public API (they keep their conformances and identity).
- Package layering: `IO Events` and `IO Completions` targets gain a dep on
  `swift-executors`'s `Executors` product (currently neither depends on it;
  only `IO Blocking` does). This is a real architectural change to weigh.
- Performance: one extra method-call indirection on `enqueue` and `drain`.
  Both are likely inlined out for `final class` + monomorphic dispatch, but
  this should be benchmarked against the existing `io-bench` baseline.

### Why this isn't the recommended action

1. The cost (new public type + new package dep + design + benchmarking) is
   comparable to the savings (~60 LOC).
2. The duplicated code is mechanical and unlikely to drift — both loops are
   in the same package, owned by the same author, and any change to one is
   trivially mirrored to the other.
3. The user's stated goal is consolidation in `swift-executors` — but the
   conformances themselves can't move there (per Options A and B above), and
   moving only the queue helper is a narrower win than the user's framing
   implies. If the user accepts that scope, the helper is worth doing; if the
   user expected consolidation of the *conformances*, the helper does not
   deliver that.

---

## Summary

| Conformance         | Recommendation              | Effort | Public API break? |
|---------------------|-----------------------------|--------|-------------------|
| `IO.Event.Loop`     | **Option D** — keep duplication | None  | No                |
| `IO.Completion.Loop`| **Option D** — keep duplication | None  | No                |
| (optional follow-up)| Option C — extract `PollingJobQueue` shared between the two IO loops | M | No                |

## Order of operations (only if Option C is accepted)

If the user accepts the optional follow-up:

1. **Land in `swift-executors`:** new file
   `Sources/Executors/Kernel.Thread.PollingJobQueue.swift` declaring the
   helper class. Tests in
   `Tests/Executor Tests/Kernel.Thread.PollingJobQueue Tests.swift`. No public
   API surface in any other package changes.

2. **Add `swift-executors` dep to `IO Events` target** in
   `swift-foundations/swift-io/Package.swift` (lines 67–82). Same for
   `IO Completions` target (lines 87–101).

3. **Refactor `IO.Event.Loop`** (`Sources/IO Events/IO.Event.Loop.swift`):
   replace `sync`, `jobs`, `drainBuffer`, `isRunning` with a single
   `queue: Kernel.Thread.PollingJobQueue` stored property; rewrite
   `enqueue(_:)` and `drainJobs()` as one-line forwards/wraps; rewrite
   `shutdownCleanup`/`fatalCleanup` to call `queue.markShutdown()`. Run
   `swift test --filter "IO Events Tests"` and the io-bench suite to
   verify no regression.

4. **Refactor `IO.Completion.Loop`** (`Sources/IO Completions/IO.Completion.Loop.swift`):
   same shape. Verify with `swift test --filter "IO Completions Tests"`.

5. **Document** the new helper in
   `swift-foundations/swift-executors/Documentation.docc/`.

If the user does not accept Option C, **no work is required.** Today's three
conformances are correctly placed.

---

## Open questions

1. **Should the wakeup channels themselves consolidate?** `IO.Event.Wakeup.Channel`
   (a plain `struct` with `signal: @Sendable () -> Void`) and
   `IO.Completion.Wakeup.Channel` (`@Witness` struct with `_wake` and `_close`)
   are similar in shape but distinct types living in different `IO` targets.
   They are *not* in scope for this triage — they're domain types, not executor
   conformances — but if Option C lands, the helper's `wake` parameter would
   pull these closer together and make the case for unifying them slightly
   stronger. Surface for the user to consider separately.

2. **Is there a path for `Kernel.Thread.Executor` to optionally use an fd-based
   wakeup (e.g., `signalfd` + `epoll`) so it could compose with the IO loops?**
   Out of scope for the immediate triage. Would be a substantial rewrite of
   `Kernel.Thread.Executor` for no obvious portability or perf benefit, and
   would not address the run-loop body divergence (the IO loops still need
   driver-specific dispatch phases that have no analog in `Kernel.Thread.Executor`).
   Mention only — not recommended.

3. **`Kernel.Thread.Synchronization<1>`'s API surface is asymmetric.** The
   IO loops use `withLock` only; they never call `wait`/`signal`/`broadcast`
   on the condvar. Is there a `Kernel.Thread.Mutex` (just the mutex, no
   condvar) that the IO loops could use instead, dropping the unused-condvar
   carrying cost? Out of scope, but flagged.

4. **`isRunning` flag is unused on the executor thread for both IO loops.**
   The flag is set under lock by `shutdownCleanup` / `fatalCleanup`, and
   *checked* under lock by `enqueue(_:)` to decide inline fallback. Within
   `runLoop()`, the loop uses `shouldHalt` (a non-locked, executor-thread-only
   flag) to decide exit. That's fine — `isRunning` is the cross-thread visible
   flag, `shouldHalt` is the thread-confined exit signal. Worth a sentence in
   the new helper's doc if Option C lands.
