# NIO-Inspired Capability Additions for swift-io, swift-kernel, and swift-executors

<!--
---
version: 1.0.0
created: 2026-04-16
last_updated: 2026-04-16
status: RECOMMENDATION
tier: 2
scope: cross-package (swift-io + swift-kernel + swift-executors)
related:
  - swift-foundations/Research/io-vs-nio-comparative-analysis.md (predecessor)
  - swift-foundations/swift-io/Research/io-architecture.md
  - swift-foundations/swift-io/Research/io-phase-2-plan.md
---
-->

## Context

The predecessor document [io-vs-nio-comparative-analysis.md](io-vs-nio-comparative-analysis.md) identified candidate additions to swift-io and its upstream (swift-kernel, swift-executors), inspired by Apple's swift-nio. The predecessor analysed the state of the world; this investigation proposes what to do about it.

Scope is strictly bounded to the three packages named in the title. Proposals that would extend to swift-sockets, swift-file-system, or stub packages (swift-http, swift-transport-layer-security, etc.) are out of scope — those warrant their own research once swift-io is stable.

## Question

Which capabilities present in swift-nio — and absent from swift-io or its upstream — should swift-io, swift-kernel, or swift-executors consider adding, and where should each addition live?

## Methodology

Per [RES-004]:

1. Enumerate candidate capabilities from swift-nio.
2. For each: describe NIO's implementation (source cited).
3. **Contextualize** per [RES-021]: concretize the proposal in swift-io's type system and measure its compatibility with the witness invariants. This is the critical step — it rejects "NIO has it" arguments that collapse under translation.
4. Classify each candidate:
   - **Adopt** — belongs; strong case; concrete placement.
   - **Defer** — belongs in principle; blocked on some precondition.
   - **Reject** — dismissed by contextualization.
5. Assign placement (swift-io, swift-kernel, swift-executors, or elsewhere).

**Evaluation criteria**:

| Criterion | Description |
|-----------|-------------|
| C1: Preserves witness axioms | Value-type `IO`, `@Sendable` closures, typed throws, `async` signature |
| C2: `~Copyable`-friendly | Descriptor parameters must allow `borrowing`/`consuming` annotations |
| C3: Typed-throws-friendly | No introduction of `any Error` |
| C4: Executor-binding-friendly | Does not require a new executor concept |
| C5: Layer discipline | Lives in the correct superrepo / package |
| C6: Marginal utility | Solves an actual downstream need, not just "NIO has it" |

## Analysis

### Candidate 1: Deadline-bound I/O — `io.read(..., deadline:)`

**NIO provenance**: NIO lacks a channel-level deadline; timing is composed externally through `EventLoop.scheduleTask(deadline:)` (`apple/swift-nio/Sources/NIOCore/EventLoop.swift:34+`) returning `Scheduled<T>`, or at application layer. However, the *pattern* of I/O with deadline is universal (e.g. `SO_RCVTIMEO`, HTTP request timeouts).

**Current state in swift-io**: the witness signature is

```swift
let _read: @Sendable (
    _ from: borrowing Kernel.Descriptor,
    _ into: Memory.Buffer.Mutable
) async throws(IO.Error) -> Int
```

(`swift-io/Sources/IO Core/IO.swift:136–140`). `IO.Error.timeout` is a declared case (`swift-io/Sources/IO Core/IO.Error.swift`) with no producer in any current strategy.

**Contextualization**: a deadline could be either:

- **(a)** a per-call parameter extending the witness shape (new closure parameter, new method overload), or
- **(b)** a separate capability the consumer composes via `withTaskGroup` + `Task.sleep`.

Option (a) requires adding a fifth closure (or expanding `_read`/`_write`/`_ready` to `(..., deadline:)`). Each strategy implements deadline natively:

- Blocking: `poll(fd, timeout_ms)` before the syscall, or `SO_RCVTIMEO`-style.
- Events (reactor): race the registration wait against an internal timer on the same executor.
- Completions (proactor): `IORING_OP_LINK_TIMEOUT` SQE chained to the read — natively expressive.

Option (b) already works and is the standard Swift pattern. However, it leaks a `Task.sleep` hop and cannot express `IORING_OP_LINK_TIMEOUT` efficiently — the proactor advantage is lost.

**Verdict**: **Adopt**. Extend the witness with deadline overloads. Each strategy implements with its most efficient mechanism.

**Placement**: swift-io.

| Criterion | Assessment |
|-----------|------------|
| C1 Witness axioms | Preserved (added closures, same shape) |
| C2 `~Copyable` | Compatible — descriptor remains `borrowing` |
| C3 Typed throws | `IO.Error.timeout` already exists |
| C4 Executor binding | Unchanged |
| C5 Layer | swift-io |
| C6 Utility | High — proactor native support is a measurable win |

**Implementation note**: deadline representation should reuse existing `Kernel.Clock` or swift-clocks' `Duration`; not swift-io's concern to define a new time type.

---

### Candidate 2: Vectored I/O — `readv`/`writev`/`sendmsg`/`recvmsg`

**NIO provenance**: NIO uses `writev(2)` for gathered writes in `IOData.writev(...)` and `DatagramVectorReadManager` for UDP vector reads (`apple/swift-nio/Sources/NIOPosix/DatagramVectorReadManager.swift`). The primitives are used under the hood; user-visible only via `IOData` and vector-read configuration.

**Current state in swift-io**: witness accepts a single `Memory.Buffer` / `Memory.Buffer.Mutable`. `swift-kernel` exposes `Kernel.IO.Read.read` / `Kernel.IO.Write.write` — single-buffer only.

**Contextualization**: vectored I/O requires passing `[iovec]` (or its typed counterpart) to the kernel. In swift-io's type system:

- `Memory.Buffer.Vector` / `Memory.Buffer.Mutable.Vector` — a non-owning collection of `Memory.Buffer`s. swift-memory-primitives is the correct home.
- swift-kernel: `Kernel.IO.Read.Vector.read(...)`, `Kernel.IO.Write.Vector.write(...)` — raw syscall wrappers.
- swift-io witness: add closures `_readv` / `_writev` (and optionally `_sendmsg` / `_recvmsg` for UDP once swift-sockets needs them).

The contract "stable address for the duration of the enclosing `try await`" extends naturally to each buffer in the vector.

**Strategy impact**:
- Blocking: straightforward — call `readv(2)` / `writev(2)`.
- Events: same readiness-then-syscall loop, just with vectored syscall.
- Completions: `IORING_OP_READV` / `IORING_OP_WRITEV` are first-class io_uring ops — zero additional conceptual load.

**Verdict**: **Adopt**. High leverage: writev is a performance-critical primitive for any TCP-level implementation that composes multiple buffers (e.g., framing protocols without intermediate copies), and the proactor supports it natively.

**Placement**:
- `swift-memory-primitives`: `Memory.Buffer.Vector`, `Memory.Buffer.Mutable.Vector`.
- `swift-kernel`: vectored syscall wrappers.
- `swift-io`: witness extension with `_readv` / `_writev` closures.

| Criterion | Assessment |
|-----------|------------|
| C1 Witness axioms | Preserved |
| C2 `~Copyable` | Compatible |
| C3 Typed throws | Compatible |
| C4 Executor binding | Unchanged |
| C5 Layer | Multi-package; respects layering |
| C6 Utility | High (writev alone justifies) |

---

### Candidate 3: Shared-singleton `shutdown()`

**NIO provenance**: `EventLoopGroup.shutdownGracefully(queue:)` is a first-class lifecycle primitive in NIO. Failure to call it on a `MultiThreadedEventLoopGroup` leaks OS threads; NIO enforces this assertively.

**Current state in swift-io**: `IO.Event.Actor.shared()` (`swift-io/Sources/IO Events/IO.Event.Actor.swift:222–244`) and `IO.Completion.Actor.shared()` (`swift-io/Sources/IO Completions/IO.Completion.Actor.swift:200–224`) are process-lifetime singletons cached in a `Result`. Actor `deinit` calls `polling.shutdown()` / `completion.shutdown()`, but a process-scoped singleton's `deinit` never fires. `IO.Blocking.shared.shutdown()` is referenced in `swift-io/README.md` without verification that a public method exists.

**swift-sockets/HANDOFF.md** documents this directly: Linux test-suite hang traced to proactor threads surviving the cooperative pool's last tick because actor deinit is never dispatched.

**Contextualization**: any of:

- **(a)** `public static func shutdown() async` on each `*.Actor` type — best effort, idempotent, safe.
- **(b)** `IO.Scope { io in … }` helper that tears down on exit.
- **(c)** Integration with swift-graceful-shutdown when it materializes.

(a) is immediately actionable and compositional. (b) adds sugar but is not load-bearing. (c) is architectural.

**Verdict**: **Adopt (a) immediately**. This is not a NIO-parity nicety; it is an outstanding correctness gap.

**Placement**: swift-io.

| Criterion | Assessment |
|-----------|------------|
| C1 Witness axioms | N/A (actor concern) |
| C2 `~Copyable` | N/A |
| C3 Typed throws | `throws(Never)` or non-throwing |
| C4 Executor binding | Unchanged |
| C5 Layer | swift-io |
| C6 Utility | Blocks CI cleanliness on Linux |

**Implementation note**: shutdown on the cached `Result` value must be re-entrant (concurrent callers) and must handle "already shut down" as a no-op, not an error.

---

### Candidate 4: Test infrastructure — fakes and observation helpers

**NIO provenance**: `EmbeddedEventLoop` and `EmbeddedChannel` (`apple/swift-nio/Sources/NIOEmbedded/Embedded.swift:1+`) allow synchronous pipeline driving with manual time advancement. `AsyncTestingEventLoop`/`AsyncTestingChannel` cover async paths. `EventCounterHandler`, `ByteToMessageDecoderVerifier`, `NIOHTTP1TestServer` cover specific concerns.

**Current state in swift-io**:
- `@Witness` generator emits `IO.unimplemented()` (trap on call) and `IO.observe { before } after: { after }` (wraps the witness), documented at `swift-io/Sources/IO Core/IO.swift:88–104`.
- `@Witness(.mock)` generation is **disabled** for IO because the macro cannot emit `borrowing Kernel.Descriptor` for parameter types (`swift-io/Sources/IO Core/IO.swift:92–98`).
- `IO Test Support` target is minimal scaffolding.
- `IO.Event.Actor.init(source:)` accepts a caller-supplied `Kernel.Event.Source` — already a fake-injection point (`swift-io/Sources/IO Events/IO.Event.Actor.swift:118–129`).

**Contextualization**:

- **(a)** Add `public static func fake(...) -> IO` to swift-io that returns a witness whose closures are pre-programmed (e.g., `IO.fake(read: { _, _ in 42 }, write: …)`). Hand-maintained equivalent of `@Witness(.mock)`.
- **(b)** Expand `Kernel.Event.Source.fake(...)` with a programmable ticker that the user-space reactor test can drive manually. Partial precedent: `swift-io/Research/event-fake-controller-poll-error-injection.md`.
- **(c)** Nothing analogous to `EmbeddedChannel` (pipeline driving) makes sense because swift-io has no pipeline — Channel-level testing is swift-sockets' concern.
- **(d)** `@Witness` macro fix to emit `borrowing`/`consuming` for `~Copyable` parameters — this is a swift-witnesses concern, not swift-io, but unblocks (a) becoming automatic.

**Verdict**: **Adopt (a), (b)**. (d) belongs in swift-witnesses; defer it there.

**Placement**:
- `IO Test Support` (swift-io target): `IO.fake(...)`.
- `Kernel Event Primitives` (swift-kernel target): `Kernel.Event.Source.fake(...)` — may already exist in a research form; elevate to production API.

| Criterion | Assessment |
|-----------|------------|
| C1 Witness axioms | Preserved |
| C2 `~Copyable` | (a) requires hand-writing; (d) upstream fix needed |
| C3 Typed throws | Compatible |
| C4 Executor binding | Fake IO can forward to `UnownedSerialExecutor.generic` |
| C5 Layer | swift-io + swift-kernel |
| C6 Utility | High — every downstream package needs testable fakes |

---

### Candidate 5: Zero-copy transfer primitives (sendfile / splice / copy_file_range)

**NIO provenance**: NIO's `FileRegion` (`apple/swift-nio/Sources/NIOCore/FileRegion.swift:46+`) represents a file slice for `sendfile(2)`. Deprecated in favour of `NIOFileSystem`, but the capability is acknowledged.

**Current state in swift-io**: witness is read-to-buffer / write-from-buffer only. No fd-to-fd primitive.

**Contextualization**:

- Linux: `sendfile(2)`, `splice(2)`, `copy_file_range(2)` — fd-to-fd transfers with no user-space copy.
- Darwin: `sendfile(2)` only (different signature).
- io_uring: `IORING_OP_SENDFILE` not yet in mainline kernel as of this writing; `IORING_OP_SPLICE` is available.

A witness extension could take the form:

```swift
let _transfer: @Sendable (
    _ from: borrowing Kernel.Descriptor,
    _ to: borrowing Kernel.Descriptor,
    _ count: Int
) async throws(IO.Error) -> Int
```

**Blockers**:

1. Platform divergence is significant (`sendfile` signatures differ between Linux and Darwin; Darwin lacks `splice`).
2. Proactor support is partial (io_uring's zero-copy capability is fast-moving kernel territory).
3. Marginal utility: swift-file-system does not yet expose file-to-socket transfers, and the primary consumer (HTTP static-file serving) lives in stub packages.

**Verdict**: **Defer**. Good concept; wrong time. Revisit when swift-file-system grows file-to-socket APIs or when swift-http begins asking for it.

**Placement (when adopted)**:
- `swift-kernel`: platform-specific syscall wrappers.
- `swift-io`: `_transfer` witness closure.

---

### Candidate 6: Multishot readiness registration (io_uring-native efficiency)

**NIO provenance**: not applicable — NIO's io_uring backend is not multishot-native. This is inspired by io_uring itself, not NIO directly; included because it is a proactor-specific efficiency improvement that the swift-io architecture can uniquely exploit.

**Current state in swift-io**: `IO.Event.Actor.wait(for:interest:)` registers a per-call `Async.Channel.Unbounded` sender and arms the driver once per call (`swift-io/Sources/IO Events/IO.Event.Actor.swift:326–346`). On readiness, the sender is drained and the awaiter returns. Each call re-arms.

`IO.Completion.Actor.ready(from:interest:)` submits a single-shot `IORING_OP_POLL_ADD` (`swift-io/Sources/IO Completions/IO.Completion.Actor.swift:427–452`).

**Contextualization**: multishot mode (`IORING_POLL_ADD_MULTI`) submits once, receives many CQEs. For a long-lived TCP connection polled many times per second, this replaces N SQE submissions with 1. Similar efficiency win is available in kqueue via `EV_ADD` without `EV_ONESHOT`, and in epoll via level-triggered registration.

**Implementation path**:
- `swift-kernel`: expose multishot submission shape in `Kernel.Completion.Submission` (may already be partially present — see `multishot-buffer-groups-reader-writer-impact.md`).
- `swift-io`: `IO.Completion.Actor` tracks multishot-registered fds; `ready` dispatches from the registration table rather than submitting a new SQE each call.

**Blockers**: completion-table semantics become more complex — entries are no longer 1:1 with submissions. Requires careful design to preserve the cancellation handshake.

**Verdict**: **Defer** — valuable but complex; tackle after Phase 2 stabilizes. Tracking research exists: `swift-io/Research/multishot-buffer-groups-reader-writer-impact.md`.

**Placement**: swift-kernel + swift-io.

---

### Candidate 7: Thread-pool observability and thread naming

**NIO provenance**: `NIOThreadPool` has thread count, lifecycle, and in some forks thread-naming. `MultiThreadedEventLoopGroup` exposes thread identifiers.

**Current state in swift-executors**: `Kernel.Thread.Executor`, `.Polling`, `.Completion`, `.Sharded` exist. Thread identification is available via `Kernel.Thread.ID.current` (`swift-io/Sources/IO Blocking/IO.Blocking.Actor.swift:74`). Thread naming, queue-depth counters, lifecycle observation are not part of the surface.

**Contextualization**:

- **(a)** `Kernel.Thread.Executor.name` — `var name: String { get set }` setting via `pthread_setname_np` / Linux `prctl(PR_SET_NAME)`. Visible in debuggers and crash logs.
- **(b)** Counters: `submissions`, `completions`, `queueDepth`, `backlog`. Could be swift-metrics-integrated or raw `Atomic<UInt64>`.
- **(c)** Lifecycle events: `didStart`, `willShutdown`. Could be `AsyncSequence<Event>` or callbacks.

(a) is cheap, universally useful, and unambiguous. (b) and (c) warrant their own design — probably after swift-metrics integration is considered holistically.

**Verdict**: **Adopt (a)**. Defer (b), (c).

**Placement**: swift-executors.

| Criterion | Assessment |
|-----------|------------|
| C1 Witness axioms | N/A |
| C2 `~Copyable` | N/A |
| C3 Typed throws | N/A |
| C4 Executor binding | Unchanged |
| C5 Layer | swift-executors |
| C6 Utility | High for debugging; near-zero overhead |

---

### Candidates considered and rejected by contextualization

| Candidate | NIO form | Contextualization result | Verdict |
|-----------|----------|--------------------------|---------|
| `Scheduled<T>` / `RepeatedTask` | Cancellable scheduled tasks on `EventLoop` | Subsumed by `Task { try await Task.sleep(…); … }` + `.cancel()`; the executor-binding pattern ensures the task runs on the correct thread | **Reject** |
| Batch fd readiness ("wake me for any of these fds") | Native `Selector.whenReady` semantics | Equivalent achieved by launching N concurrent `io.ready(from: fd, interest: …)` tasks; the reactor's internal multiplexing already fans out. The missing API would duplicate the reactor's own work | **Reject** (document idiom instead) |
| `HighLowWatermark` backpressure primitive | `NIOAsyncSequenceProducerBackPressureStrategies` | Belongs in swift-async as a general AsyncSequence concern, not in swift-io | **Reject for swift-io** (consider for swift-async) |
| `NIOLockedValueBox` | Sendable-wrapping lock | Already covered by swift-threads' `Synchronization` primitive | **Reject** |
| `EventLoopFuture<T>` | Completion future | Direct conflict with typed-throws + native async axioms; deliberate non-goal | **Reject** |
| `Channel` / `ChannelPipeline` / `ChannelHandler` | Reference-type pipeline | Direct conflict with value-type witness axiom | **Reject for swift-io** (belongs in higher layer if at all) |
| `ByteBuffer` as interchange | CoW owned buffer | Direct conflict with "caller owns storage" contract | **Reject for swift-io** |
| `AddressedEnvelope<T>` | UDP (src, dst, payload) triple | Belongs in swift-sockets once UDP lands | **Reject for swift-io** |
| `MulticastChannel` | Join/leave group API | Belongs in swift-sockets | **Reject for swift-io** |
| `FileRegion` (sendfile) | fd slice for zero-copy send | Deferred (Candidate 5) | **Defer** |

## Outcome

**Status**: RECOMMENDATION

### Prioritized action list

| Priority | Candidate | Placement | Reason |
|----------|-----------|-----------|--------|
| P0 | Candidate 3 — shared-singleton `shutdown()` | swift-io | Outstanding correctness gap; blocks Linux CI |
| P1 | Candidate 7(a) — executor thread naming | swift-executors | Cheap, universal debuggability win |
| P1 | Candidate 4 — test fakes (`IO.fake(...)`, `Kernel.Event.Source.fake`) | swift-io + swift-kernel | Unblocks every downstream test suite |
| P2 | Candidate 1 — deadline-bound I/O | swift-io | Closes `IO.Error.timeout` without-producer gap; proactor has native support |
| P2 | Candidate 2 — vectored I/O (readv/writev) | swift-memory-primitives + swift-kernel + swift-io | High leverage for TCP-adjacent code; io_uring native |
| P3 | Candidate 6 — multishot readiness | swift-kernel + swift-io | Proactor efficiency; wait until Phase 2 stabilizes |
| P3 | Candidate 5 — zero-copy transfers (sendfile/splice) | swift-kernel + swift-io | Defer until a concrete consumer (HTTP static file, file-to-socket) exists |

### Cross-cutting recommendations

1. **Witness macro work (swift-witnesses)**: `@Witness(.mock)` generation currently drops `borrowing` / `consuming` on `~Copyable` parameters (`swift-io/Sources/IO Core/IO.swift:92–98`). Fixing this removes the need for hand-maintained `IO.fake(...)` and generalizes to every other `~Copyable`-accepting witness. Track in swift-witnesses.

2. **Contextualization as a review gate**: every future "NIO has this" proposal for swift-io should go through the same methodology this document applies — concretize in swift-io's type system, then evaluate. The rejection table above is the template: if a candidate collapses at contextualization, it does not warrant research effort.

3. **No new error cases in `IO.Error` without a producer**: `IO.Error.timeout` existed without a deadline-bound producer for several releases. Any future error case should be introduced together with the strategy implementation that produces it.

4. **Layer discipline**: nothing in this document proposes lateral or upward dependencies. Each addition either (a) lives within the package that already owns the concept, or (b) extends downward into a primitive that swift-io then consumes.

### Explicit non-goals preserved

- No `Channel`/`Pipeline`/`Handler` equivalent in swift-io.
- No `EventLoopFuture` / promise-based combinators.
- No framework-owned mandatory interchange buffer.
- No untyped throws anywhere on the public surface.
- No signal handling in swift-io (delegates to swift-signal).
- No TLS, HTTP, WebSocket, DNS in swift-io (all are distinct packages).

### Implementation order

1. **P0 first, standalone**: shutdown() is a focused correctness fix. Ship it before anything else.
2. **P1 in parallel**: thread naming (swift-executors) and test fakes (swift-io + swift-kernel) do not depend on one another.
3. **P2 after Phase 2**: deadline and vectored I/O each extend the witness. Wait for Phase 2B (events) and 2C (completions) to land, then add together so all three strategies get the new closures in one pass.
4. **P3 when demand materializes**: multishot and zero-copy are speculative without a named downstream consumer.

## References

- Predecessor: [io-vs-nio-comparative-analysis.md](io-vs-nio-comparative-analysis.md).
- swift-nio source: `/Users/coen/Developer/apple/swift-nio`.
- swift-io source: `/Users/coen/Developer/swift-foundations/swift-io`.
- Outstanding correctness issue: `/Users/coen/Developer/swift-foundations/swift-sockets/HANDOFF.md`.
- Multishot research precedent: `swift-io/Research/multishot-buffer-groups-reader-writer-impact.md`.
- Fake event source precedent: `swift-io/Research/event-fake-controller-poll-error-injection.md`.
- [RES-004] Investigation Methodology; [RES-020] Research Tiers; [RES-021] Prior Art Survey with contextualization step.
- Brachthäuser et al., "Effects as Capabilities", ECOOP 2020.
- Ahman & Bauer, "Runners in Action", ESOP 2020.
