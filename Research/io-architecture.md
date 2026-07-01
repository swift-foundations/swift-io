# swift-io Architecture

> **Subordinated to** `swift-io-thesis.md` (2026-04-20): this document
> remains the canonical concrete architecture. Its scoping/positioning
> claims defer to the thesis. The five-target split here implements
> the four signature components of `Σ_IO` (Blocking → `Σ_Blocking`;
> Events → `Σ_Event`; Completions → `Σ_Completion`; Reader/Writer →
> `Σ_Stream`; Consumer API → unified surface).

<!--
---
version: 1.2.0
created: 2026-04-14
status: COMMITTED
tier: 2
related:
  - swift-io/Research/io-performance-ceiling-measurement.md (benchmark)
  - swift-io/Research/io-phase-2-plan.md (Phase 2 execution contract)
  - swift-io/HANDOFF-io-layered-implementation-review.md (design debate)
  - swift-io/HANDOFF-io-layered-implementation-review-response.md (author response)
  - swift-io/HANDOFF-io-performance-measurement-response.md (perf decisions)
  - swift-io/Experiments/io-stacked-actor-bench/ (measurement source)
changelog:
  - v1.3: Phase 2 complete. Summary of what landed beyond v1.2:
    * Phase 2C: IO.Completion.Queue + its public-handle satellites deleted;
      IO.Completion.Loop (internal, SerialExecutor + TaskExecutor + poll)
      + IO.Completions.Actor (witness-shaped, multi-CQE cancel handshake
      per supervisor constraint #2) + IO.completions(on:) factory
      (Linux-only, #if os(Linux), per constraint #3) delivered.
      IO.Completion.Kind.poll added, wired end-to-end through
      Kernel.Completion.Submission.events + the io_uring backend's
      IORING_OP_POLL_ADD (multishot: false, edge-triggered, per
      constraint #4). Buffer-ownership contract verified empirically on
      real io_uring (Q2 experiment) — unified _read signature retained.
    * Phase 2D: IO.default() host-adaptive factory shipped in the IO
      umbrella target. Fallback chain per platform (Linux: completions
      → events → blocking; Darwin: events → blocking; other: blocking).
      Buffer-ownership contract promoted from per-factory docstrings to
      the canonical IO witness doc (constraint #1) with the exact
      "stable address for duration of try await" wording from
      Research/io-proactor-buffer-ownership.md.
    * Cross-repo groundwork: Kernel.Event.Interest moved from Kernel
      Event Primitives to Kernel Descriptor Primitives as
      Kernel.Descriptor.Interest (cross-paradigm vocabulary — Event /
      Completion both reference descriptor readiness). Typealias
      bridge preserved for the 27 existing Kernel.Event.Interest call
      sites. Kernel.Event.Poll.Events.init(interest:) projection added
      at L2 (swift-linux-standard) as the shared Interest→epoll-mask
      mapper used by both the reactor's one-shot helper and the
      io_uring POLL_ADD path.
    * Storage userData lifetime: passRetained/takeRetainedValue
      replaces passUnretained, fixing a teardown-race SIGBUS observed
      on Linux Docker when the loop thread drained CQEs after the
      consumer's frame had released its storage reference.
    * Dead-code strip: IO.Completion.Error.Lifecycle, .Operation
      cancellation/timeout/invalidSubmission, and the Failure
      typealias removed — all unreachable after the public-handle
      deletion.
    * Gates: macOS 44/21, Linux Docker (swift:6.3 + io_uring,
      aarch64) 47/22 green. No regressions. Supervisor constraints
      #1–#4 verified end-to-end.
  - v1.2: Path A correction to the TCP listener example:
    * The prior example used `result.descriptor` / `descriptor.asKernelDescriptor`
      which are not valid — `Kernel.Socket.Accept.Result` is `~Copyable` non-frozen
      and partial consumption is blocked across module boundaries (swap-with-sentinel
      workaround required); `descriptor.asKernelDescriptor` does not exist in any
      primitive.
    * Replaced with the ecosystem-consistent pattern: `Sockets.TCP.Connection` stores
      `Kernel.Descriptor` (consumed from `Kernel.Socket.Descriptor` at the accept
      boundary via the existing `Kernel.Descriptor(_ socket: consuming Kernel.Socket.Descriptor)`
      consuming initializer). Matches `swift-io/Sources/IO Events/IO.Event.Channel.swift:60`
      which stores `Kernel.Descriptor` for the same reason. Socket-specific syscall
      wrappers in iso-9945 (`Kernel.Socket.getError`, `Kernel.Socket.shutdown`, etc.)
      already accept `Kernel.Descriptor` overloads.
    * If a future sub-phase surfaces a socket-specific op that genuinely requires the
      typed form (`Kernel.Socket.Descriptor`, no generic overload available), the fix
      is to add `Kernel.Socket.Descriptor.kernelDescriptor` (borrowing view) to
      swift-kernel-primitives as a prerequisite. Not needed for Phase 2A; noted as the
      escape hatch in `Research/io-phase-2-plan.md`.
  - v1.1: Corrections from author review:
    * `.io` case removed — was invented in v1.0, not present in implementation.
    * `brokenPipe` reclassified fd-generic (EPIPE fires on pipe writes, not just sockets);
      retained in IO.Error. Only `connectionReset` (TCP ECONNRESET) and `notConnected`
      (ENOTCONN) migrate to swift-sockets.
    * Added events-strategy-accept gap to "Open Questions for Future Phases" — the
      shared-executor pattern only covers blocking accept; events accept requires
      `@_spi(...)` Selector exposure for swift-sockets.
  - v1.0: Initial architecture statement. Supersedes prior io-events-completions-fate.md
    (deleted). Written after three review cycles + benchmark + user's domain-agnostic
    directive. Locks in: domain-agnostic swift-io, witness-per-strategy, shared-executor
    pattern for domain-package composition, socket-specific code in swift-sockets.
---
-->

## Principle

**swift-io is domain-agnostic.** It provides primitive I/O dispatch over the generic `Kernel.Descriptor` handle type. It knows nothing about sockets, files, pipes, terminals, or any other kernel resource domain. Domain-specific I/O (socket accept, file open, pipe splice, etc.) belongs in domain packages (`swift-sockets`, `swift-file-system`, `swift-pipes`).

This principle is the binding constraint on every design decision below. If a proposed addition to swift-io carries knowledge of a specific resource domain, it does not belong in swift-io.

## Package Layout

```
swift-io (L3 Foundations)
├─ Sources/
│  ├─ IO Core/           Abstract IO witness + IO.Error
│  ├─ IO Blocking/       IO.blocking(_:) factory + blocking-strategy runtime
│  ├─ IO Events/         IO.events(_:) factory + reactor runtime
│  ├─ IO Completions/    IO.completions(_:) factory + proactor runtime
│  └─ IO/                Umbrella + IO.platformBest(_:)
└─ Package.swift declares five products (IO Core, IO Blocking, IO Events, IO Completions, IO)
```

Strategy targets are independent. Consumers import the strategies they need. The umbrella IO product re-exports all four and adds `IO.platformBest`.

## The IO Witness

`IO` is a `@Witness` struct holding four closures, all operating on the generic `Kernel.Descriptor`:

```swift
@Witness
public struct IO: Sendable {
    let _read: @Sendable (
        _ from: borrowing Kernel.Descriptor,
        _ into: Memory.Buffer.Mutable
    ) async throws(IO.Error) -> Int

    let _write: @Sendable (
        _ to: borrowing Kernel.Descriptor,
        _ from: Memory.Buffer
    ) async throws(IO.Error) -> Int

    let _close: @Sendable (consuming Kernel.Descriptor) async -> Void

    let _unownedExecutor: @Sendable () -> UnownedSerialExecutor
}
```

Four closures. No `_accept`, no `_connect`, no `_sendmsg`, no `_recvmsg`, no `_pread`, no `_pwrite`. Those are domain-specific and live in their respective domain packages.

`IO.Error` cases are fd-generic:

- `.brokenPipe` — EPIPE. Fires on pipe/FIFO writes with closed read end AND on socket writes with closed peer. Genuinely fd-generic; retained.
- `.timeout` — operation deadline exceeded.
- `.cancelled` — task cancellation observed.
- `.shutdown` — the IO runtime is shutting down.
- `.platform(Kernel.Error.Code)` — POSIX errno or Win32 error code not mapped to a higher-level case.

Socket-specific errors do NOT live in `IO.Error`:

- `connectionReset` (ECONNRESET, TCP-specific RST) — migrates to swift-sockets' error type.
- `notConnected` (ENOTCONN, socket-only) — migrates to swift-sockets' error type.

The `Kernel.IO.Read.Error.io(.reset)` case from prior mappings folds to `.platform(code)` in swift-io (accepting semantic loss; ECONNRESET is TCP-specific and callers wanting the precise semantic use swift-sockets). `.io(.broken)` maps to `.brokenPipe` (retained).

## Strategies

Each strategy provides a factory extension on `IO`:

| Factory | Strategy | Runtime machinery |
|---------|----------|-------------------|
| `IO.blocking(_:)` | Dedicated OS thread + POSIX syscalls with EINTR retry | `Kernel.Thread.Executor` + internal `IO.Blocking.Actor` |
| `IO.events(_:)` | Reactor (kqueue/epoll) + non-blocking syscalls | `IO.Event.Selector` / `Runtime` / `Loop` / `Driver` + internal event-strategy actor |
| `IO.completions(_:)` | Proactor (io_uring/IOCP) + submit-and-await | `IO.Completion.Queue` / `Driver` / submission / poll / cancellation + internal completion-strategy actor |
| `IO.platformBest(_:)` | `#if`-dispatches to the best available strategy per platform | Composition only — no own runtime |

The runtime machinery for events and completions is retained (~100 files across two targets). It is reactor/proactor infrastructure that is domain-agnostic — an event loop serves any fd, not just sockets. Consumer-facing socket-specific types (`IO.Event.Channel` and its satellites) that used to live alongside the runtime are **not part of swift-io**; they migrate to swift-sockets.

## Performance Positioning

Measured on Apple M3 / macOS 26.2 / Swift 6.3 (see `Research/io-performance-ceiling-measurement.md` for methodology):

| Consumer path | Per-op overhead | Use |
|---------------|----------------:|-----|
| Default (cross-hop from cooperative pool to IO's executor) | ~5 µs | Casual use, one-off I/O, non-actor consumer code. Invisible against blocking syscall cost. |
| **Shared-executor (TCA26)** — consumer actor forwards `unownedExecutor` to `io.unownedExecutor` | **~320 ns** | **Canonical for actor-based production consumers** (servers, services, stacked actor components). |

Production consumers should adopt the shared-executor pattern. The default path is a convenience.

## Shared-Executor Pattern

A consumer actor forwards its `unownedExecutor` to the IO's:

```swift
actor MyService {
    let io: IO
    init() { self.io = IO.blocking() }

    nonisolated var unownedExecutor: UnownedSerialExecutor {
        io.unownedExecutor
    }

    func operation() async throws {
        // All io.* calls stay on io's thread — no cross-hop.
        try await io.read(from: fd, into: buffer)
    }
}
```

Swift's runtime executor-match check elides the hop on every `await` when the consumer's executor identity equals IO's. Measured at ~320 ns per op, below raw syscall cost.

## Composition: swift-sockets (and other domain packages)

Domain packages own their resource-specific types and operations. They compose with swift-io for byte-level I/O and executor sharing.

### Example: `swift-sockets` TCP listener (accept pattern)

```swift
// In swift-sockets
public actor Listener {
    let io: IO
    var _fd: Kernel.Socket.Descriptor  // listener socket descriptor

    public nonisolated var unownedExecutor: UnownedSerialExecutor {
        io.unownedExecutor  // share IO's thread
    }

    public func accept() throws(Sockets.Error) -> Sockets.TCP.Connection {
        // Runs on io's executor thread via actor isolation.
        var result = try Kernel.Socket.Accept.accept(_fd)

        // Kernel.Socket.Accept.Result is ~Copyable non-frozen; partial consumption
        // is blocked across the iso-9945 module boundary. Swap-with-sentinel.
        var extracted = Kernel.Socket.Descriptor.invalid
        Swift.swap(&result.descriptor, &extracted)

        return Sockets.TCP.Connection(
            descriptor: Kernel.Descriptor(consume extracted),
            peer: result.address,
            io: io
        )
    }
}

public struct Connection: ~Copyable, Sendable {
    public let descriptor: Kernel.Descriptor
    public let peer: Kernel.Socket.Address.Storage
    public let io: IO

    public mutating func read(into buffer: Memory.Buffer.Mutable) async throws(IO.Error) -> Int {
        try await io.read(from: descriptor, into: buffer)
    }
    // etc.
}
```

Rationale for the descriptor type:

- `Connection` stores `Kernel.Descriptor`, not `Kernel.Socket.Descriptor`. `io.read` /
  `io.write` / `io.close` take `borrowing Kernel.Descriptor` and there is no public
  borrowing view from `Kernel.Socket.Descriptor` to `Kernel.Descriptor` in the
  primitives — only the consuming transfer (`Kernel.Descriptor(_: consuming Kernel.Socket.Descriptor)`).
- The ecosystem already follows this convention: `swift-io/Sources/IO Events/IO.Event.Channel.swift:60`
  stores `Kernel.Descriptor?` for exactly the same reason. Socket-specific syscall wrappers
  in iso-9945 (`Kernel.Socket.getError(_:)`, `Kernel.Socket.Shutdown.shutdown(_:)`, etc.)
  accept `Kernel.Descriptor` overloads, so keeping the generic form in `Connection`
  does not block future socket-specific methods.
- If a future sub-phase surfaces a socket-specific op that genuinely requires the typed
  form, the fix is a single-primitive addition (`Kernel.Socket.Descriptor.kernelDescriptor`
  borrowing view) in swift-kernel-primitives. Documented as an escape hatch in
  `Research/io-phase-2-plan.md`; not needed for Phase 2A.

swift-sockets:
- Owns socket lifecycle (accept, connect, bind, listen, shutdown).
- Owns socket-specific types (Sockets.TCP.Listener, Sockets.TCP.Connection, etc.).
- Delegates byte-level I/O to the IO witness over `Kernel.Descriptor` stored at the accept boundary.
- Uses the shared-executor pattern to run socket syscalls on IO's thread.

For the blocking strategy, swift-sockets needs **zero new public API from swift-io** — just `io.unownedExecutor`. For events and completions strategies (later), swift-sockets may need richer access to swift-io's runtime (selector registration, submission queue). That design is deferred until events/completions strategies land.

## Domain Allocation Reference

| Concern | Home |
|---------|------|
| Generic read / write / close on `Kernel.Descriptor` | swift-io |
| Strategy dispatch (blocking / events / completions / platformBest) | swift-io |
| Reactor runtime (Selector, Loop, Driver) | swift-io (IO Events target, internal) |
| Proactor runtime (Queue, submission, poll, cancellation) | swift-io (IO Completions target, internal) |
| Socket accept / connect / sendmsg / recvmsg | swift-sockets |
| Socket address parsing, DNS resolution | swift-sockets |
| TCP / UDP / UNIX-domain socket types | swift-sockets |
| Half-close, split, Reader/Writer, shutdown | swift-sockets (migrating from swift-io's current Sources/IO Events/) |
| File open, stat, mmap, xattr, path operations | swift-file-system |
| pread / pwrite / preadv / pwritev | swift-file-system |
| splice, tee, sendfile | swift-pipes (if/when built) |

## POSIX Wrapper Policy

swift-io's blocking strategy uses POSIX wrappers with EINTR retry (`POSIX.Kernel.IO.Read.read`, `POSIX.Kernel.IO.Write.write`, `POSIX.Kernel.Socket.Accept.accept` where applicable), not raw syscalls. EINTR is a caller-nuisance, not a caller-actionable event; automatic retry is the Right Thing for blocking I/O.

Existing call sites using raw `Kernel.IO.Read.read` etc. are migrated to the POSIX variants as part of Phase 1.

## Rejected Designs

Don't reopen or rebuild these:

| Rejected | Why |
|----------|-----|
| `IO.Socket` witness in swift-io | Domain-authority violation — accept is socket-specific. |
| `IO.Event.Channel` / `Reader` / `Writer` / `Split` / `HalfClose` / `Shutdown` as swift-io public types | Socket-specific ergonomics — migrate to swift-sockets. |
| `IO.Completion.Channel` as swift-io public type | Same reasoning. |
| `swift-io-primitives` L1 split | YAGNI. `@Witness` macro is L3 (loses `unimplemented()`/`observe`/`Calls` generation). No consumer needs IO without the blocking impl. |
| Context / Stream / Reader / Writer / Run types | Pre-Shape-B design, superseded. Delete the `Sources/IO/IO.Context*.swift`, `IO.Stream*.swift`, `IO.Reader.swift`, `IO.Writer.swift`, `IO.Run*.swift` files. |
| Admission gating / dispatch API | Pre-Shape-B, backpressure now via actor queue. |
| Raw-syscall policy (no EINTR retry) | Surfaces spurious `.platform(EINTR)` to consumers for no benefit. Use POSIX wrappers. |
| `any SerialExecutor` on public types | Breaks embedded Swift compatibility. Concrete executor types only. |
| Actor.run fast-path as public API | Forces `@Sendable` body, consume-into-body for ~Copyable descriptors. |
| `sending` + `isolated Self` closure body | Swift 6.3 region-checker limitation — does not compile. |

## Open Questions for Future Phases

These do not affect the current architectural commitment but are noted for future work:

- **Events-strategy accept for swift-sockets** (Gap 3 from author review): the shared-executor pattern works for blocking accept (swift-sockets runs the accept syscall on swift-io's executor thread). For events-strategy accept, swift-sockets must register the listener fd with the reactor's `Selector` and await read-readiness. This requires cross-package access to `IO.Event.Selector`, which plain `package` visibility (SE-0386, intra-package only) does not provide. When the events factory lands, `Selector` and analogous completions runtime types must be exposed via `@_spi(ResourceBackend) public` (or similar SPI name) for swift-sockets and future resource-domain packages. Blocking-only Phase 1 does not need this; surface it when events factory lands.
- **Cancellation and timeout composition**: `Task.cancel` must propagate through blocking-thread syscalls (requires `pthread_kill(SIGUSR2)` or equivalent), events-strategy poll exit, and completions-strategy `IORING_OP_ASYNC_CANCEL`. Phase 5+ work.
- **Buffer-ownership contract under proactor**: explicit kernel-buffer-registration may need a dedicated witness op (`readRegistered` etc.) rather than the unified `_read` signature. Decide when completions strategy is implemented.
- **Multi-connection contention**: N consumer actors sharing one IO executor thread. Relevant for swift-sockets thread-pool sizing. Benchmark pre-v1.0.
- **p99 / p99.9 tail latency**: requires per-op timestamp methodology. Pre-v1.0 ship-readiness.

## Supporting Evidence

- `Research/io-performance-ceiling-measurement.md` — measurement backing the shared-executor positioning.
- `Experiments/io-stacked-actor-bench/` — benchmark source.
- `HANDOFF-io-layered-implementation-review.md` — fresh-perspective review that surfaced the Events/Completions elided runtime, domain-authority vs strategy-dispatch debate, and buffer ownership concern.
- `HANDOFF-io-layered-implementation-review-response.md` — author's response converging on Framing E (later superseded by domain-agnostic directive).
- `HANDOFF-io-performance-measurement-response.md` — performance decisions and open-question list.

## Canonical Reference

This document is the canonical architecture statement. Prior design docs (`perfect-api.md`, `io-blocking-executor-binding.md`, `io-witness-design-literature-study.md`, `io-context-actor-analysis.md`) contain useful historical context but have been superseded by this document where they disagree. The deleted `io-events-completions-fate.md` encoded Framing E with `IO.Socket` in swift-io, which was retracted under the domain-agnostic directive.
