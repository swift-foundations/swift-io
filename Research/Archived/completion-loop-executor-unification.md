# Completion.Loop Executor Unification

<!--
---
version: 1.0.0
created: 2026-04-15
status: COMMITTED
tier: 3
related:
  - swift-io/Research/io-architecture.md (parent architecture doc)
  - swift-io/Research/executor-conformance-triage.md (executor inventory)
  - swift-executors/Research/executor-package-design.md (Polling design)
  - HANDOFF.md (Phase 3b dispatch)
changelog:
  - v1.0: Initial evaluation of Options A and B for Phase 3b. Option B
    implemented and verified (macOS 44/21 green). Status COMMITTED.
---
-->

## Background

`IO.Completion.Loop` is a 362-LOC proactor I/O loop that serves as `SerialExecutor` + `TaskExecutor` + io_uring submission/completion handler. It manages its own OS thread, job queue, synchronization, and 5-phase run loop.

Phase 3a successfully migrated `IO.Event.Loop` (reactor) to `Kernel.Thread.Executor.Polling`. That migration was clean because both are reactors — `source.poll()` returns domain events directly. The tick body dispatches those events to channel senders. Zero adaptation needed; Event.Loop went from 341 LOC to 145 LOC.

Phase 3b asks: should `Completion.Loop` follow the same path?

## The Structural Mismatch

Event.Loop and Polling are isomorphic — reactor ↔ reactor. Completion.Loop and Polling are structurally different — proactor ↔ reactor.

| Aspect | Polling (reactor) | Completion.Loop (proactor) |
|---|---|---|
| Blocking primitive | `source.poll()` — epoll_wait / kevent | `notification.wait()` — 8-byte eventfd read |
| Domain events from | Poll return value (kernel events) | Separate ring buffer (`completion.drain()`) |
| Run loop phases | drain → wait → tick | drain → cancel → flush → wait → drain-CQEs → dispatch |
| Phase ordering constraint | None — poll IS the event source | flush MUST precede wait (submissions must reach kernel before blocking) |
| Wakeup mechanism | `waitSource.wakeup` fires to epoll/kqueue wakeup fd | `completion.wakeup` fires to io_uring notification eventfd |

The blocking primitives are different kernel objects serving different roles. Polling's `waitSource.wait()` calls `source.poll()` (epoll_wait). Completion.Loop's `notification.wait()` calls `Kernel.IO.Read.read(descriptor, into: buf)` — a blocking 8-byte read on an eventfd. These cannot be substituted.

## Option A — Polling Adapter

### Mechanism

Create a `Kernel.Event.Source` (epoll instance) that monitors the io_uring notification eventfd. Pass this to Polling. The tick callback receives `Kernel.Event`s from epoll and performs the proactor's domain work.

### The Flush-Before-Wait Ordering Problem

Polling's run loop is:

```
drain jobs → wait (blocking) → tick(events) → repeat
```

Completion.Loop requires:

```
drain jobs → check cancellations → flush → wait → drain CQEs → dispatch
```

The flush MUST happen before the blocking wait — otherwise SQEs submitted by actor jobs (during `drainJobs`) never reach the kernel before we block. Here is the concrete deadlock path:

1. External thread enqueues a submit job → `Polling.enqueue()` → `wakeup.wake()` fires
2. Polling run loop: `waitSource.wait()` returns (wakeup) → `drainJobs()` runs the submit job → SQEs added to io_uring submission ring
3. Polling run loop: `waitSource.wait()` blocks on epoll — **but SQEs aren't flushed.** The kernel doesn't know about them.
4. The io_uring eventfd never fires because nothing was submitted to the kernel.
5. **Deadlock.**

Note that the wakeup from step 1 was consumed by the `wait` return in step 2. By the time we reach the next `wait` in step 3, there is no pending wakeup.

### Workaround: Submit-Path Wakeup

The submit path could fire `wakeup.wake()` after adding SQEs to the ring. Then:

1. `drainJobs()` runs submit → SQEs added → `wakeup.wake()` fires
2. `waitSource.wait()` returns immediately (wakeup pending)
3. `tick`: cancel → flush → drain CQEs → dispatch

This avoids the deadlock but has costs:

- One extra eventfd write syscall per submit cycle
- The blocking wait always returns immediately in the submit → flush → complete cycle, defeating the purpose of the blocking poll
- The wakeup must bridge from `IO.Completion.Wakeup.Channel` (which fires to the io_uring eventfd) to `waitSource.wakeup` (which fires to the epoll wakeup fd) — these are **separate file descriptors**. The bridge requires either: (a) submit fires both wakeups, or (b) the adapter registers the io_uring eventfd in the epoll so its readiness wakes `waitSource.wait()`, and submit also fires the Polling wakeup for the flush cycle.

### The Ignored-Events Problem

Polling's tick receives `UnsafeBufferPointer<Kernel.Event>` — the events from epoll. For Event.Loop, these ARE the domain events (fd readiness notifications). The tick dispatches them directly.

For Completion.Loop, these events would say "the eventfd fired" — a single event carrying no domain information. The tick would **ignore its events parameter entirely** and always do the same work: cancel → flush → drain the io_uring ring → dispatch CQEs. If the consumer ignores the core data the executor provides, the executor model is wrong for this consumer.

### Assessment

**Code reduction**: Remove ~120 LOC of executor machinery (thread, queue, sync, enqueue, drain, shutdown). Add ~60 LOC for tick body (cancel + flush + drain + dispatch) and adapter setup. Net: ~60 LOC removed. Estimated result: 362 → ~300.

Note: Event.Loop achieved a much larger reduction (341 → 145) because its tick was 15 lines of event dispatch. Completion.Loop's tick would be 50+ lines implementing the full proactor run loop minus the executor shell.

**Architectural cleanliness**: Poor.

- tick ignores its events parameter — a design smell indicating abstraction mismatch
- The flush-before-wait ordering requires a workaround (submit-path wakeup) that couples the submit path to the adapter's wake mechanism
- Extra epoll instance wrapping an eventfd — one level of indirection that adds complexity without adding capability

**Blast radius**: Moderate.

- Requires `IO.Completion.Driver` `@Witness` ABI change: new `_asEventSource` or `_notificationDescriptor` witness to expose the eventfd for epoll registration
- New `Kernel.Event.Source` created per Completion.Loop instance (extra epoll_create + epoll_ctl at setup)
- Linux-only adapter code (Darwin uses Event.Loop/kqueue; this adapter only serves io_uring)
- Phase 3a files are NOT modified — the adapter is entirely in swift-io's Completions target

**Performance**: Overhead within budget but measurable.

| Cost | Per-setup | Per-iteration |
|------|-----------|---------------|
| epoll_create1 | 1 syscall | — |
| epoll_ctl (add eventfd) | 1 syscall | — |
| epoll_wait (replaces eventfd read) | — | ~same as eventfd read |
| Submit-path wakeup (eventfd write) | — | +1 syscall per submit cycle |
| Total overhead vs current | +2 syscalls | +1 syscall per submit |

The per-iteration overhead of one extra eventfd write per submit cycle is ~30-50 ns on modern Linux. Within the ≤50 ns budget but consuming most of it for adapter mechanics rather than domain work.

**Maintainability**: Poor.

A developer reading the tick body would ask: "Why does this ignore the events parameter?" The answer requires understanding the reactor/proactor distinction and the adapter indirection. The code tells you what it does but not why the events are irrelevant. The submit-path wakeup would need a comment explaining the flush-ordering constraint — a non-local invariant that's easy to break.

## Option B — Primitives-Only Refactor

### Mechanism

Replace the ad-hoc executor machinery in Completion.Loop with the same L1/L3 primitives that Polling uses. Keep the 5-phase run loop and `notification.wait()` blocking.

Specific replacements:

| Current (ad-hoc) | Replacement (L1/L3 primitive) | Benefit |
|---|---|---|
| `Kernel.Thread.Synchronization<1>` | `Kernel.Thread.Mutex` | Same primitive Polling uses; clearer intent (mutex, not condvar) |
| `ContiguousArray<UnownedJob>` + drainBuffer | `Executor.Job.Queue` × 2 | O(1) `drain(into:)` via Deque swap; pre-allocated capacity |
| `isRunning: Bool` (lock-protected) | `Executor.Shutdown.Flag` | Atomic relaxed load on hot path; no lock acquisition |
| Manual swap + removeAll drain | `Queue.drain(into:)` + `while dequeue()` | Idiomatic, fewer lines, O(1) transfer |

What stays unchanged:

- Thread management: `Kernel.Thread.trap` + `Ownership.Transfer.Retained` (same pattern as Polling)
- `notification.wait()` as the blocking primitive (proactor's natural wait mechanism)
- 5-phase run loop: drain → cancel → flush → poll → dispatch
- `IO.Completion.Wakeup.Channel` for cross-thread signaling
- All domain logic: submit, checkCancellations, CQE dispatch, shutdown cleanup

### Assessment

**Code reduction**: ~80 LOC removed.

- `drainJobs()`: 12 lines → 6 lines (Queue handles swap/drain mechanics)
- `enqueue()`: simplifies with Queue.enqueue replacing ContiguousArray.append
- Shutdown: `isRunning` flag merge with `Executor.Shutdown.Flag.set()` + relaxed check
- Init: remove `Synchronization()` allocation, replace with Mutex + Queue inits
- Import list: drop `Thread_Synchronization`, add `Executor_Primitives`

Estimated result: 362 → ~280.

**Architectural cleanliness**: Excellent.

- The resulting structure honestly represents what Completion.Loop IS: a proactor with different blocking semantics than a reactor
- Each primitive has a clear role matching its purpose: Queue for jobs, Flag for shutdown, Mutex for synchronization
- No adapter, no ignored events, no impedance mismatch
- The same primitive vocabulary as Polling (Queue, Flag, Mutex) makes the two loops structurally comparable without forcing them into the same shell

**Blast radius**: Zero.

- No `IO.Completion.Driver` witness ABI change
- No new kernel resources
- No new platform-specific adapter code
- No changes to Phase 3a files
- No changes to `swift-executor-primitives`
- No changes to `swift-executors`

**Performance**: Net improvement.

| Change | Impact |
|--------|--------|
| `Executor.Job.Queue.drain(into:)` | O(1) Deque swap vs O(n) `swap + removeAll(keepingCapacity:)` |
| `Executor.Shutdown.Flag.isSet` | Relaxed atomic load vs lock-protected Bool read |
| No additional kernel resources | No extra epoll/eventfd setup or per-iteration overhead |

The hot-path improvement from lock-protected `isRunning` → relaxed atomic `Shutdown.Flag` is small but real (~10-20 ns saved per iteration on the flag check).

**Maintainability**: Excellent.

A developer reading the code sees:

- The same primitive types used in Polling (Queue, Shutdown.Flag, Mutex) — "these loops share vocabulary"
- A run loop whose phases map directly to io_uring semantics — "drain → cancel → flush → poll → dispatch, that's the proactor pattern"
- No hidden indirection, no non-local invariants, no comments explaining why data is being ignored

## Criterion #8 Revision

The original criterion #8 (executor toolkit phase gate) asked Completion.Loop to use Polling. This was written before the reactor/proactor mismatch was understood.

Option B satisfies the **intent** of criterion #8: eliminate duplicated executor machinery and use shared primitives. It does not satisfy the **letter**: Completion.Loop does not hold a Polling instance. The criterion should be revised to reflect the structural reality — forcing a proactor through a reactor shell produces worse code, not better.

Proposed revision: "Completion.Loop uses L1 executor primitives (Executor.Job.Queue, Executor.Shutdown.Flag) to eliminate ad-hoc machinery. Polling is reserved for reactor-pattern loops."

## Recommendation

**Option B — Primitives-Only Refactor.**

The reactor ↔ proactor structural difference is not an abstraction to paper over. It is a genuine architectural distinction that should be expressed in code. Forcing Completion.Loop through Polling would:

1. Introduce a flush-before-wait ordering problem requiring a submit-path wakeup workaround
2. Create an adapter where the consumer ignores the executor's core data (events)
3. Add per-iteration overhead (extra epoll layer, extra wakeup syscall) for zero functional benefit
4. Require a driver witness ABI change (`IO.Completion.Driver`) for a single Linux-only consumer
5. Add non-local invariants that are easy to break and hard to explain

Option B achieves the meaningful unification: shared primitives (Queue, Flag, Mutex) across both executor implementations, with each loop owning the run loop structure that matches its paradigm.

### Trade-offs Accepted

| Trade-off | Why it's acceptable |
|---|---|
| Completion.Loop does not hold Polling | Criterion #8 should be revised — the intent (shared primitives) is satisfied |
| Two run loop implementations exist | They represent two genuinely different paradigms (reactor vs proactor) |
| Less LOC reduction (~80 vs ~60 net for A) | The remaining LOC in B is honest domain logic; the "removed" LOC in A is replaced by adapter glue that's harder to maintain |
| No single "executor type" for all I/O loops | Premature unification would hide a real architectural boundary |

### Implementation Scope

If approved, the implementation is:

1. Replace imports: drop `Thread_Synchronization`, add `Executor_Primitives`
2. Replace `sync: Kernel.Thread.Synchronization<1>` → `queueLock: Kernel.Thread.Mutex`
3. Replace `jobs: ContiguousArray<UnownedJob>` → `jobs: Executor.Job.Queue`
4. Replace `drainBuffer: ContiguousArray<UnownedJob>` → `drainBuffer: Executor.Job.Queue`
5. Replace `isRunning: Bool` → `shutdownFlag: Executor.Shutdown.Flag`
6. Rewrite `drainJobs()` using `Queue.drain(into:)` + `while dequeue()`
7. Rewrite `enqueue()` using `Queue.enqueue()`
8. Rewrite shutdown using `Flag.set()` + `Flag.isSet` checks
9. Verify: `swift test` green on macOS (Completion.Loop is Linux-only for io_uring, but the executor machinery compiles and tests on macOS via the driver witness mock path)
