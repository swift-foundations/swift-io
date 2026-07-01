# io_uring Integration Architecture

<!--
---
version: 2.0.1
last_updated: 2026-05-31
status: RECOMMENDATION
statusDetail: "Frontmatter reconciled to the Outcome's self-declared RECOMMENDATION (Option B integrated-eventfd for Linux, Option C IOCP-as-Loop for Windows; Option A rejected). Triaged 2026-05-31 per [META-002]; was IN_PROGRESS."
tier: 2
supersedes: []
related:
  - architecture-refactor.md
  - completion-queue-ownership-redesign.md
---
-->

## Context

swift-io has two I/O backends: Events (reactor, kqueue/epoll) and Completions
(proactor, io_uring/IOCP). The Events backend was refined into a single-thread
architecture: `IO.Event.Loop` (SerialExecutor + TaskExecutor + poll thread),
`IO.Event.Runtime` actor, and `IO.Event.Selector` handle. Completions has a
separate poll thread with no executor integration.

The conversation that prompted this research reached a key insight: **io_uring
does not need its own poll thread**. Submissions are non-blocking ring buffer
writes. Completions can be discovered via eventfd registered with epoll. The
existing Events loop already blocks on epoll_wait — piggybacking io_uring
notifications is free.

This document investigates how to integrate io_uring into the existing
single-thread Events architecture, where the io_uring driver and its primitives
should live in the platform stack, and how the design extends to IOCP on Windows.

## Question

How should io_uring completions be integrated into swift-io's single-thread
architecture? Specifically: where does the driver live, how are completions
discovered, and how does the unified `IO.run` API select the right backend?

## Prior Art

### Existing codebase

| Component | Location | Status |
|-----------|----------|--------|
| `Kernel.Readiness.Driver` | swift-kernel | Complete (kqueue + epoll) |
| `Kernel.Readiness.Backend.platformDefault()` | swift-kernel | Complete |
| io_uring syscall primitives | swift-linux-primitives (89 files) | Complete |
| `IO.Completion.IOUring` driver + Ring | swift-io (IO Completions target) | Working, wrong location |
| `IO.Completion.Driver` witness | swift-io | Working, preliminary |
| `IO.Event.Loop` (executor + poll) | swift-io (IO Events target) | Complete |
| `IO.Event.Driver` wrapping `Kernel.Readiness` | swift-io | Complete |
| epoll eventfd wakeup | swift-kernel (`Driver+Epoll.swift`) | Complete |
| io_uring eventfd registration | swift-io (`IOUring.swift:290-331`) | Complete |

### External systems

| System | Language | Approach | Integration model |
|--------|----------|----------|-------------------|
| monoio | Rust | io_uring OR epoll (mutually exclusive) | `poll-io`: epoll fd as PollAdd SQE inside uring |
| libxev | Zig | Separate backends, same API shape | Compile-time or runtime selection, no bridging |
| glommio | Rust | io_uring only, no epoll | Pure proactor |
| tokio-uring | Rust | Separate from tokio's epoll runtime | NOT integrated — two runtimes |
| Windows IOCP | — | IOCP IS the event loop | 1 per completion port |
| Go netpoller | Go | epoll only, no io_uring | 1 per runtime |

### monoio (bytedance/monoio)

monoio does NOT run epoll and io_uring simultaneously. They are mutually
exclusive backends selected at startup via `FusionRuntime` enum. The `poll-io`
feature flag is the closest to hybrid integration: it registers the epoll fd
as a `PollAdd` SQE inside the io_uring ring. When that CQE fires, the loop
calls `poll.tick(Duration::ZERO)` — a non-blocking epoll drain. io_uring
remains the sole blocking wait mechanism.

**One loop iteration** (io_uring path, `UringInner`):
1. Drain task queue (with starvation bound `len * 2`)
2. Poll main future
3. If idle: install eventfd read SQE + PollAdd SQE (poll-io) + timeout SQE
4. `submit_and_wait(1)` — single syscall for submit + block
5. `tick()` — inline CQ drain: for each CQE, match `user_data` to slab slot,
   wake the associated Rust future's waker

**SQ access**: Direct push via `sq.push(&sqe)`. No MPSC queue. Submission
deferred to `park()` (not per-SQE). **CQ drain**: Inline for-loop in `tick()`,
not callback-based. **Userdata**: Slab index (bounded, safe).

**OpAble trait**: Each I/O operation implements both `uring_op()` (returns SQE)
and `legacy_call()` (performs syscall directly). The runtime dispatches based
on the active backend. This dual-target pattern is the most practical way to
support both models without duplicating higher-level logic.

### libxev (mitchellh/libxev)

libxev uses completely separate backend implementations with the same API shape.
No attempt to bridge reactor into proactor. Each backend defines its own
`Completion` struct, `Operation` enum, and `Loop` type. The dynamic API wraps
them in tagged unions for runtime selection.

**Unified abstraction**: There is no shared type that maps across backends.
`DynamicCompletion` is a tagged union of all candidate backend completions.
The unification is at the API surface (same method names, same parameter
shapes), not at the type level.

**Buffer model**: `ReadBuffer = union { array: *[4096]u8, slice: []u8 }`.
Same type for both reactor and proactor — the buffer must remain valid until
the callback fires. For proactor (io_uring), the kernel holds the pointer.
For reactor (epoll), the buffer is consumed in the synchronous syscall after
readiness. The ownership contract is identical from the consumer's perspective.

**CQ drain** (io_uring): Inline for-loop. `ring.copy_cqes(&cqes, wait)` →
batch-copy up to 128 CQEs → for each: cast `user_data` to `*Completion`,
invoke callback. Callbacks return `.disarm` or `.rearm`.

### Key takeaways from prior art

1. **No system truly runs epoll and io_uring concurrently as co-equal loops.**
   monoio's `poll-io` is the closest: epoll is subordinate to io_uring
   (registered as a PollAdd SQE). Our design (eventfd in epoll) inverts this:
   io_uring is subordinate to epoll (registered as an eventfd). Both achieve
   one thread.

2. **The dual-op pattern** (monoio's `OpAble`) is practical for supporting
   both reactor and proactor from the same higher-level code.

3. **Deferred submission** is universal. No system calls `io_uring_enter` on
   every SQE push. Submission happens at park/tick time.

4. **CQ drain is always inline** — a for-loop in the event loop, not callbacks
   or actor hops. This validates our "no actor" decision.

5. **libxev's approach** (separate backends, same API shape) is simpler but
   less flexible. Our approach (integrated eventfd) is more ambitious but
   enables mixed reactor+proactor workloads on one thread.

## Analysis

### Option A: Separate Loop (status quo)

io_uring gets its own `IO.Completion.Loop` with a dedicated OS thread, mirroring
`IO.Event.Loop`. The two loops are independent.

```
Darwin:  IO.Event.Loop (kqueue)
Linux:   IO.Event.Loop (epoll) + IO.Completion.Loop (io_uring)  ← 2 threads
Windows: IO.Completion.Loop (IOCP)
```

**Advantages**:
- Minimal change to existing Completions code
- Clear separation of concerns
- Completion poll can block independently

**Disadvantages**:
- Two OS threads on Linux (one for epoll, one for io_uring)
- Job dispatch split across two executors
- No way to share a single event loop for mixed readiness + completion workloads
- Contradicts the single-thread architecture established by Events

**Assessment**: The current Completions code already works this way. It's
functional but architecturally wrong for the long term.

### Option B: Integrated eventfd (recommended for Linux)

io_uring completions are discovered via eventfd registered with epoll. The
Events loop (`IO.Event.Loop`) handles both readiness events AND io_uring
completions in a single thread.

```
Darwin:  IO.Event.Loop (kqueue)                     ← 1 thread
Linux:   IO.Event.Loop (epoll + io_uring eventfd)   ← 1 thread
Windows: IO.Completion.Loop (IOCP)                   ← 1 thread (see Option C)
```

**Mechanism**:

1. Create io_uring ring (`io_uring_setup`)
2. Create eventfd (`eventfd(0, EFD_CLOEXEC | EFD_NONBLOCK)`)
3. Register eventfd with io_uring (`IORING_REGISTER_EVENTFD`)
4. Register eventfd with epoll (`EPOLLIN | EPOLLET`, data = sentinel)
5. The Events loop runs: `drain jobs → poll(epoll_wait) → dispatch events`
6. When epoll_wait returns with eventfd readable:
   - Drain eventfd (read the counter)
   - Peek io_uring CQ ring (non-blocking: load head/tail, iterate CQEs)
   - Resolve completions (resume continuations)
7. When epoll_wait returns with fd readiness:
   - Dispatch to channels as before

**Submission path** (unchanged from current Completions):
- Consumer calls `IO.run(fd) { reader, writer in writer.write(all:) }`
- Internally: fill SQE in shared-memory ring buffer (non-blocking)
- `io_uring_enter(toSubmit)` to flush (or batch and flush in the loop)
- Consumer suspends on continuation
- Loop wakes when CQE arrives via eventfd → resolves continuation

**Advantages**:
- One thread on Linux — matches Darwin and Windows
- io_uring submissions are non-blocking (ring buffer writes)
- Completions are discovered passively via epoll (no busy-wait, no separate poll)
- The Loop executor is the sole serialization domain (no actor needed)
- Mixed workloads (some fds via readiness, some via completion) share one loop
- `withTaskExecutorPreference(loop)` works for both backends

**Disadvantages**:
- io_uring CQ drain runs on the same thread as epoll dispatch (latency coupling)
- Requires changes to `IO.Event.Loop.runLoop()` to handle a second event source
- The Loop becomes platform-aware (epoll-only on generic Linux, epoll+io_uring when available)

**Latency coupling mitigation**: io_uring CQ drain is O(completions) with no
syscalls (shared-memory read). epoll dispatch is also O(events). Both are fast.
The coupling is comparable to Tokio's single-threaded runtime, which handles
both in one loop iteration.

### Option C: IOCP as the Loop (Windows)

On Windows, there is no epoll. IOCP (`GetQueuedCompletionStatusEx`) IS the
event notification mechanism. The Loop on Windows should be backed by IOCP
directly, not by a non-existent readiness driver.

```
Windows: IO.Event.Loop backed by IOCP (one thread, one completion port)
```

This means `IO.Event.Loop` (or a unified `IO.Loop`) has platform-specific
internals:
- Darwin: kevent() in runLoop
- Linux: epoll_wait() + io_uring CQ drain in runLoop
- Windows: GetQueuedCompletionStatusEx() in runLoop

**Implication**: The Loop abstracts the platform-specific poll mechanism. The
consumer API (`IO.run`) is platform-agnostic.

**Not in scope for this document** — IOCP integration requires Windows
primitives that don't exist yet. The design should be compatible but
implementation is deferred.

## Platform Stack Placement

### Current state

| Layer | Package | Has |
|-------|---------|-----|
| L1 | swift-linux-primitives | io_uring syscall wrappers (89 files) |
| L3 | swift-kernel | `Kernel.Readiness` + `Kernel.Readiness.Driver` (kqueue, epoll) |
| L3 | swift-io | `IO.Completion.IOUring` (driver + ring management) |

### Target state (per architecture-refactor.md Phases 2-4)

| Layer | Package | Should have |
|-------|---------|-------------|
| L1 | swift-linux-primitives | io_uring syscall wrappers (already done) |
| L3 | swift-kernel | `Kernel.Completion` resource + `Kernel.Completion.Driver` witness |
| L3 | swift-linux | `Kernel.Completion.Driver+IOUring` backend |
| L3 | swift-io | `IO.Event.Loop` consuming `Kernel.Completion` for CQ draining |

### What Kernel.Completion should look like

Following the `Kernel.Readiness` pattern:

```swift
// swift-kernel: Kernel.Completion (resource)
public struct Completion: ~Copyable, Sendable {
    public let driver: Driver
    public let descriptor: Kernel.Descriptor    // io_uring fd or IOCP handle
    public let wakeup: Wakeup.Channel           // eventfd signal
    // Ring state is platform-specific — owned by driver closures
}

// swift-kernel: Kernel.Completion.Driver (witness)
public struct Driver: Sendable {
    public let capabilities: Capabilities
    public let _submit:  (borrowing Kernel.Descriptor, ...) throws(Error) -> Void
    public let _flush:   (borrowing Kernel.Descriptor) throws(Error) -> Int
    public let _harvest: (borrowing Kernel.Descriptor, inout [...]) throws(Error) -> Int
    public let _close:   (borrowing Kernel.Descriptor) -> Void
}
```

**Key difference from Readiness**: No `_register`, `_modify`, `_deregister`,
`_arm`. Completion drivers submit operations, not register interest. The
lifecycle is: submit → harvest → done. No re-arming.

### What stays in swift-io

- `IO.Event.Loop` — the executor + poll thread (platform-specific internals)
- `IO.Event.Runtime` — the coordination actor (Events only — Completions
  does not need an actor per completion-queue-ownership-redesign.md)
- `IO.Completion.Queue` — the consumer handle (wraps submission to the Loop)
- `IO.Completion.Operation`, `Entry`, `Submission` — the operation lifecycle types

## Integrated Loop Design (Linux)

### IO.Event.Loop changes

The Loop's `runLoop()` method gains an optional io_uring integration point:

```
mainLoop:
    drain jobs
    if shouldHalt: break
    epoll_wait(deadline) → events
    for event in events:
        if event is wakeup:
            continue                    // wakeup already handled
        if event is io_uring_eventfd:
            drain eventfd
            drain CQ ring → resolve completions
        else:
            dispatch to channel senders  // existing readiness path
```

The io_uring ring, entries table, and submission queue are thread-confined to
the Loop (same pattern as the existing `registrations` table and `driver`).

### Submission path

Submissions bypass the Loop thread for the hot path:

1. Consumer fills SQE via `IO.Completion.Queue.submit(operation)`
2. SQE written to shared-memory ring buffer (non-blocking, no thread needed)
3. `io_uring_enter(toSubmit)` called to notify kernel (syscall from consumer task)
4. Consumer suspends on continuation
5. Kernel completes the operation, writes CQE, signals eventfd
6. Loop wakes (epoll_wait returns with eventfd), drains CQ, resolves continuation

**Alternative**: Batch submissions in the Loop. Consumer enqueues to MPSC queue,
Loop fills SQEs and calls `io_uring_enter` once per iteration. This batches
syscalls but adds latency. The current Completions code uses this pattern.
Decision: **defer to implementation — try direct submission first, fall back to
batched if contention on the SQ ring is measured**.

### No actor (confirmed)

Per `completion-queue-ownership-redesign.md` (CONVERGED): the actor was
intentionally removed from Completions. The poll thread (now the Loop) is the
sole lifecycle authority for completion resolution. The Loop's job queue handles
lifecycle operations (shutdown). No `IO.Completion.Runtime` actor.

```
// WHY: No actor — see completion-queue-ownership-redesign.md [PATTERN-016]
// The proactor has 1:1 operation-to-waiter mapping. No fan-out.
// The actor caused hangs due to split ownership between two
// serialization domains. The Loop thread IS the serializer.
```

## Comparison

| Criterion | A: Separate Loop | B: Integrated eventfd | C: IOCP Loop |
|-----------|-----------------|----------------------|--------------|
| Threads on Linux | 2 | **1** | N/A |
| Threads on Windows | 1 | N/A | **1** |
| Executor integration | Split | **Unified** | **Unified** |
| Mixed workloads | Separate | **Shared** | **Shared** |
| Implementation complexity | Low | Medium | Medium |
| Latency coupling | None | Low (CQ drain is O(n) memread) | None |
| Platform stack alignment | No | **Yes** | **Yes** |

## Outcome

**Status**: RECOMMENDATION

### Recommended approach

**Option B (integrated eventfd) for Linux. Option C (IOCP as Loop) for Windows.
Option A is rejected.**

One thread per platform. io_uring integrates into the existing Events loop via
eventfd on Linux. IOCP replaces epoll as the Loop's backing mechanism on Windows.
Darwin uses kqueue only (no completion backend, by design).

### Execution sequence

| Step | What | Where | Depends on |
|------|------|-------|------------|
| 1 | Create `Kernel.Completion` + `Kernel.Completion.Driver` | swift-kernel | — |
| 2 | Create `Kernel.Completion.Driver+IOUring` backend | swift-linux | Step 1 |
| 3 | Integrate io_uring CQ drain into `IO.Event.Loop.runLoop()` | swift-io | Step 2 |
| 4 | Refactor `IO.Completion.Queue` to submit via Loop | swift-io | Step 3 |
| 5 | Create IO.Reader/IO.Writer backed by Completions | swift-io | Step 4 |
| 6 | Wire `IO.run(fd)` to use io_uring on Linux when available | swift-io | Step 5 |

Steps 1-2 are platform stack work. Steps 3-4 are the integration. Steps 5-6
are the consumer API bridge.

### What can be deleted after integration

The entire `IO Completions` target (62 files) is replaced by:
- `Kernel.Completion` resource + driver in swift-kernel/swift-linux (~10 files)
- io_uring integration in `IO.Event.Loop` (~50 LOC addition to runLoop)
- `IO.Completion.Queue` refactored to use the Loop (~1 file)
- Operation types retained but simplified (no separate Poll, Entry, Submission)

### IOCP compatibility

The design is IOCP-compatible. On Windows, the Loop's runLoop() would call
`GetQueuedCompletionStatusEx` instead of `epoll_wait`. The completion resolution
path is identical (match completion to entry, resolve continuation). Windows
has no readiness driver, so the Loop only handles completions.

## io_uring Advanced Features

Three features affect the integration design significantly.

### Multishot operations

Multishot operations break the 1:1 assumption. One SQE produces N CQEs.

| Operation | Flag | Kernel |
|-----------|------|--------|
| Poll | `IORING_POLL_ADD_MULTI` | 5.13 |
| Accept | `IORING_ACCEPT_MULTISHOT` | 5.19 |
| Recv | `IORING_RECV_MULTISHOT` | 6.0 |
| Recvmsg | multishot prep function | 6.0 |

**CQE stream protocol**: `IORING_CQE_F_MORE` (bit 1) in `cqe->flags`:
- Flag **set**: more CQEs will follow. Request remains armed.
- Flag **cleared**: terminal CQE. Request is dead. Resubmit to continue.

**Dispatch table implication**: The Loop needs a persistent handler per
multishot SQE, not a single continuation:

```
user_data → MultishotState {
    handler: (CQE) → Void        // each intermediate CQE
    terminal: (CQE) → Void       // when IORING_CQE_F_MORE is absent
}
```

The handler stays alive until the terminal CQE. This is NOT a continuation
list — it's a persistent registration, closer to Events' channel pattern
than to single-shot completion.

**Does multishot change the "no actor" decision?** No. The dispatch table
is thread-confined to the Loop. The Loop drains CQEs inline and invokes
handlers directly — no fan-out to multiple consumers. Multishot accept
produces N connection descriptors, but each is dispatched to the same
handler (the accept loop). This is 1:handler, not N:N.

**Cancellation**: `io_uring_prep_cancel()` targeting the `user_data`.
Kernel produces a terminal CQE (without `IORING_CQE_F_MORE`) with
`res = -ECANCELED`. Normal cleanup.

**Multishot recv constraint**: Requires `IOSQE_BUFFER_SELECT` (must use
provided buffers). Requires `len = 0`. Must NOT set `MSG_WAITALL`.

### SQPOLL mode

`IORING_SETUP_SQPOLL` creates a kernel thread that polls the SQ ring.
Submissions don't need `io_uring_enter()` — just write the SQE and update
the tail pointer. The kernel picks it up.

**Does NOT eliminate all syscalls**:
- Submission: eliminated (kernel thread polls SQ)
- Completion wait: still needs `io_uring_enter(IORING_ENTER_GETEVENTS)`
  unless busy-polling the CQ ring
- Wakeup after idle: kernel sets `IORING_SQ_NEED_WAKEUP` in SQ flags
  after `sq_thread_idle` ms. App must call `io_uring_enter(SQ_WAKEUP)`.

**Permissions**: No special privileges required since kernel 5.13.

**CPU cost**: 100% of one core while active. Backs off after idle timeout.
Recommended only for high-throughput servers.

**Requires fixed files**: `io_uring_register_files()` + `IOSQE_FIXED_FILE`
on all SQEs. Cannot use regular file descriptors.

**Eventfd interaction**: `IORING_REGISTER_EVENTFD` works independently of
SQPOLL. Completions still signal the eventfd. This is how we integrate
into epoll — SQPOLL is orthogonal.

**Recommended setup flags** (kernel 6.1+):
- `IORING_SETUP_COOP_TASKRUN`: Disable IPIs for completion delivery
- `IORING_SETUP_DEFER_TASKRUN`: All completion work deferred until
  explicit `io_uring_enter(GETEVENTS)`. Requires `SINGLE_ISSUER`.
- `IORING_SETUP_SINGLE_ISSUER`: Only one task submits (our Loop thread)

**Decision**: SQPOLL is a performance knob, not a structural choice. The
default path uses batched submission via the Loop. SQPOLL can be enabled
via configuration when the workload justifies it. This resolves open
question 1 (direct vs batched): **batched by default, SQPOLL for servers**.

### Provided buffer groups

The answer to open question 4 (buffer ownership bridge).

**Two APIs** (prefer the newer one):

| API | Kernel | Mechanism |
|-----|--------|-----------|
| `IORING_OP_PROVIDE_BUFFERS` | 5.7 | SQE-based, requires syscall to re-provide |
| `IORING_REGISTER_PBUF_RING` | 5.19 | Ring-mapped shared memory, re-provide without syscall |

**Ring-mapped provided buffers** (`IORING_REGISTER_PBUF_RING`) is correct
for new code. The application and kernel share a ring buffer of buffer
descriptors. The kernel picks a buffer at completion time. The application
re-provides after processing by writing to the ring — no syscall.

**How the application knows which buffer was used**:
Buffer ID in upper 16 bits of `cqe->flags`:
```
IORING_CQE_F_BUFFER (bit 0): a buffer was selected
buffer_id = cqe->flags >> 16   (16-bit, 0–65535)
```

**Re-providing buffers** (ring-mapped API):
1. Process the data in `pool[buffer_id]`
2. `io_uring_buf_ring_add(ring, buf, size, buffer_id, mask, idx)`
3. `io_uring_buf_ring_advance(ring, 1)` — userspace ring write, no syscall

**Incremental consumption** (`IOU_PBUF_RING_INC`, kernel 6.12+):
Multiple recv completions share portions of one large buffer.
`IORING_CQE_F_BUF_MORE` flag means buffer is partially consumed —
don't re-provide until the flag clears.

**IO.Reader backed by provided buffer groups**:

```
1. Allocate N buffers, register as buffer ring with group ID G
2. Submit multishot recv with IOSQE_BUFFER_SELECT, buf_group = G
3. On each CQE:
   - Extract buffer_id from cqe->flags
   - Yield pool[buffer_id] data to consumer (as Span<UInt8>)
   - Re-provide buffer via ring write
4. On terminal CQE: resubmit multishot recv
```

The consumer calls `reader.forEach { chunk in }`. The Reader owns the
buffer ring and the pool. The kernel selects buffers. The consumer never
allocates, never sees the buffer ownership transfer. This fulfills the
"no buffer management" Tier 0 promise.

**Kernel version baseline**: 5.19 gets ring-mapped provided buffers +
multishot accept. 6.0 adds multishot recv. 6.1 adds DEFER_TASKRUN.
**Recommended minimum: kernel 6.1.**

## Open Questions

1. ~~**Direct vs batched submission**~~: **Resolved**. Batched by default
   (submissions accumulate, flushed once per Loop iteration). SQPOLL
   available as a configuration knob for high-throughput servers.

2. **SQ ring contention**: If multiple tasks submit concurrently, the SQ ring
   needs synchronization. Options: Mutex on SQ writes, or funnel through the
   Loop's MPSC queue. The current Completions code uses MPSC. monoio uses
   direct push (single-threaded). **Recommendation**: MPSC queue, matching
   the current pattern. The Loop drains and fills SQEs on its thread.

3. **io_uring availability**: Should the Loop always create an io_uring ring
   on Linux, or only when the consumer requests completion-based I/O?
   **Recommendation**: Lazy creation. `IO.Event.Loop` creates the ring on
   first completion-based operation. Readiness-only workloads pay no cost.

4. ~~**Buffer ownership bridge**~~: **Resolved**. Provided buffer groups
   (ring-mapped, kernel 5.19+) are the IO.Reader implementation strategy.
   The Reader owns the buffer ring. The consumer sees `Span<UInt8>` chunks.
   No buffer management exposed.

5. **Multishot handler lifecycle**: The dispatch table for multishot state
   needs a cleanup strategy. When does the handler get removed if the
   kernel silently drops the multishot (e.g., peer disconnect)? The terminal
   CQE (without `IORING_CQE_F_MORE`) is the removal signal. But if the
   CQE is lost (kernel bug, ring overflow), the handler leaks. Needs a
   timeout or ring-overflow audit.

6. **Ring overflow**: If the CQ ring is full, the kernel drops CQEs. This
   is silent data loss. The application must size the CQ ring appropriately
   (`IORING_SETUP_CQSIZE`) and monitor `cq.overflow` counter. The Loop
   should check this counter periodically and log/alert on overflow.

## References

- `swift-io/Research/architecture-refactor.md` — normative migration spec
- `swift-io/Research/completion-queue-ownership-redesign.md` — no-actor rationale
- `swift-kernel: Kernel.Readiness.Driver+Epoll.swift` — epoll eventfd pattern
- `swift-io: IO.Completion.IOUring.swift:290-331` — io_uring eventfd registration
- `swift-linux-primitives: Linux.Kernel.IO.Uring.Register.Eventfd.swift` — eventfd opcodes
- monoio (`bytedance/monoio`) — FusionRuntime, poll-io feature, OpAble trait
- libxev (`mitchellh/libxev`) — unified API shape over separate backends
- [io_uring(7) man page](https://man7.org/linux/man-pages/man7/io_uring.7.html)
- [io_uring and networking in 2023 — liburing wiki](https://github.com/axboe/liburing/wiki/io_uring-and-networking-in-2023)
- [Efficient IO with io_uring — kernel.dk](https://kernel.dk/io_uring.pdf)
- [SQPOLL tutorial — Lord of the io_uring](https://unixism.net/loti/tutorial/sq_poll.html)
- [io_uring 6.11/6.12 changelog — liburing wiki](https://github.com/axboe/liburing/wiki/What's-new-with-io_uring-in-6.11-and-6.12)
