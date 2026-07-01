# Architecture Refactor: Platform Stack Alignment

> **Status**: Normative. This document defines the target architecture, policy invariants,
> and migration contracts for the swift-io platform stack refactor.
>
> **Source**: Converged plan from Claude + ChatGPT collaborative discussion (3-round).
> Temporary source: `/tmp/swift-io-arch-refactor-converged.md`.

## Goal

Move event/completion notification policy from swift-io down to the platform stack
(swift-darwin, swift-linux, swift-windows, swift-kernel). Redesign swift-io as a consumer
of Kernel-provided drivers rather than their hidden host. Redesign swift-io's public API
as a high-level, operation-centric async byte I/O library. swift-sockets sits above
swift-io and owns transport/protocol lifecycle.

## Target Architecture

### Responsibility Split

| Package | Owns | Does Not Own |
|---------|------|-------------|
| **swift-darwin** | `Kernel.Readiness.Driver` (kqueue) | Poll thread, dispatch, channels |
| **swift-linux** | `Kernel.Readiness.Driver` (epoll), `Kernel.Completion.Driver` (io_uring) | Poll thread, dispatch, channels |
| **swift-windows** | `Kernel.Completion.Driver` (IOCP) | Poll thread, dispatch, channels |
| **swift-kernel** | `Kernel.Readiness.Driver` + `Kernel.Completion.Driver` witness types, `Backend` factories | All implementation |
| **swift-io** | Poll/completion thread, dispatch loop, Selector/Scope lifecycle, async byte I/O API | Event notification policy, platform syscalls |
| **swift-sockets** | connect/listen/accept, addressing, TCP/UDP, framing, socket options | Byte transport, cancellation, backpressure |

### Inert Driver Definition

A **driver** is a stateful but threadless facility. It:

- **Maintains state**: registration table, ID generation, staleness metadata.
- **Does not own threads**: the caller supplies the thread that blocks in `poll()`.
- **May block the calling thread**: `poll()`/`harvest()` is a blocking syscall on the caller's thread.
- **Does not start, stop, or schedule autonomous execution resources**.

The calling code (swift-io) is responsible for:
- Hosting the dedicated OS thread that calls `driver.poll()` in a loop.
- Processing registration requests before each poll cycle.
- Dispatching normalized events to consumer channels.
- Coordinating shutdown and lifecycle.

### Separate Semantic Families

Two driver families exist. They are not unified under a common protocol.

**Readiness (reactor)**: Notifies when a descriptor is ready for an operation.
- `Kernel.Readiness.Driver` backed by kqueue (Darwin) or epoll (Linux).
- Consumer does: `poll() -> [events]`, then performs the actual I/O.

**Completion (proactor)**: Performs the operation and notifies on completion.
- `Kernel.Completion.Driver` backed by io_uring (Linux) or IOCP (Windows).
- Consumer does: `submit(operation)`, then `harvest() -> [completions]`.

No premature universal witness. The families have different contracts: readiness delivers
descriptors ready for I/O; completion delivers finished I/O operations with results.

## Driver Contract (Four Parts)

### 1. Registration

Register, modify, or deregister interest in a descriptor (readiness) or submit an
operation (completion). Returns an opaque token.

```
register(handle, descriptor, interest) -> ID
modify(handle, id, interest) -> Void
deregister(handle, id) -> Void
```

### 2. Waiting

Blocking poll/harvest call invoked by the caller-owned thread.

```
poll(handle, deadline?, into: &buffer) -> count
```

### 3. Wake

Interrupt blocking wait for control-plane changes (new registrations, shutdown).

```
wakeup(handle) -> Channel    // Channel.wake() is Sendable
```

### 4. Normalization

Emit cross-platform results keyed by opaque token.

**Readiness payload**: `Kernel.Event(id, interest, flags)`
- `interest`: which directions are ready (`.read`, `.write`, `.priority`)
- `flags`: conditions (`.hangup`, `.readHangup`, `.writeHangup`, `.error`)
- Conditions are first-class payload fields, not thrown errors.

**Completion payload**: `token + operation kind + outcome (success/error/cancelled)`

## Seven Policy Invariants

These invariants define the observable behavioral contract of the readiness driver.
They must be preserved unchanged across the platform migration (Phases 2-5).
Phase 1 behavioral tests encode each invariant as a black-box test.

### INV-1: Registration Identity

**Statement**: Each `register()` call produces a unique, non-zero ID. IDs are never
reused within a process.

**Observable contract**:
- Successive `register()` calls on the same or different driver instances return
  distinct IDs.
- No ID equals zero. Zero is reserved as the "no registration" sentinel (epoll wakeup
  eventfd uses default poll data = .zero; kqueue EVFILT_USER uses ident = 0).
- First ID produced is 1.

**Implementation invariant** (for reference, not part of the behavioral test):
Process-global `Atomic<UInt64>` counter, starts at 0, `wrappingAdd(1).newValue`.
Wrapping at UInt64.max is acceptable (~600 years at 1M registrations/sec).

### INV-2: Ownership Lifecycle

**Statement**: The driver takes consuming ownership of a dup'd descriptor on register.
The dup'd descriptor is closed exactly once: on deregister, close, or error recovery.
No descriptor leaks.

**Observable contract**:
- After `register()` succeeds, the registration exists in the driver's registry.
- After `deregister()` succeeds, the registration no longer exists.
- `deregister()` is idempotent: calling it on an already-deregistered or never-registered
  ID succeeds silently.
- `close()` drains all remaining registrations.
- If `register()` fails after the kernel call, the dup'd descriptor is still closed.

**Ownership model**: `Registration.Entry` is `~Copyable`. It owns the dup'd
`Kernel.Descriptor`. The entry's removal path (`deregister` or `close`) is the
only path that closes the dup'd fd. No aliasing, no double-close.

### INV-3: Delta Correctness

**Statement**: `modify()` computes the set difference between old and new interests.
Only changed interests produce kernel modifications.

**Observable contract**:
- `modify(id, interest: [.read, .write])` from `[.read]` adds `.write` only.
- `modify(id, interest: [.read])` from `[.read, .write]` removes `.write` only.
- `modify(id, interest: current)` (no change) issues no kernel syscall.
- After `modify()`, the stored interest matches the new value.

**Why this matters**: Avoids spurious state changes at the kernel level. Double-arming
or double-disarming can cause platform-specific errors or missed events.

### INV-4: One-Shot Re-Arm

**Statement**: After the kernel delivers a readiness event, the filter is automatically
disabled. The consumer must call `arm()` to re-enable notification.

**Observable contract**:
- After registration, the filter starts enabled (events that occur before first `arm()`
  are captured as permits, not lost).
- After event delivery, no further events are delivered until `arm()` is called.
- `arm()` re-enables the filter for the specified interest.
- The lifecycle is: register (enabled) -> event -> disabled -> arm -> enabled -> event -> ...

**Platform mechanism**:
- kqueue: `EV_DISPATCH` auto-disables; `arm()` uses `EV_ADD|EV_ENABLE|EV_CLEAR|EV_DISPATCH`.
- epoll: `EPOLLONESHOT` auto-disables; `arm()` uses `EPOLL_CTL_MOD` with `EPOLLONESHOT`.

### INV-5: Normalization

**Statement**: Platform-specific raw events are converted to the cross-platform
`Kernel.Event(id:interest:flags:)` format before reaching the consumer.

**Observable contract**:
- A raw read-ready event produces `interest: .read`.
- A raw write-ready event produces `interest: .write`.
- A raw EOF/hangup event produces `flags: .hangup` plus the directional flag
  (`.readHangup` or `.writeHangup`).
- A raw error event produces `flags: .error`.
- Conditions (hangup, error) are flags in the event payload. They are never thrown
  as errors from `poll()`.

**Platform mapping** (for reference):

| Platform | Read | Write | Priority | EOF | Error | Peer-close |
|----------|------|-------|----------|-----|-------|------------|
| kqueue | `EVFILT_READ` | `EVFILT_WRITE` | - | `EV_EOF` | `EV_ERROR` | `EV_EOF` on read |
| epoll | `EPOLLIN` | `EPOLLOUT` | `EPOLLPRI` | `EPOLLHUP` | `EPOLLERR` | `EPOLLRDHUP` |

### INV-6: Staleness Suppression

**Statement**: Events for IDs that are no longer registered are silently discarded.
The consumer never observes a stale event.

**Observable contract**:
- If a descriptor is deregistered between the kernel returning an event and the
  driver processing it, the event is dropped.
- Wakeup events (EVFILT_USER on kqueue, eventfd on epoll) are never delivered
  as registration events.
- `poll()` returns only events whose IDs are present in the current registry.

**Mechanism**: After `poll()` returns raw events, each event's ID is looked up in
the registry under lock. Events with unknown IDs are skipped.

### INV-7: Wake Responsiveness

**Statement**: A call to `wakeup.wake()` from any thread interrupts a blocking
`poll()` call, causing it to return promptly.

**Observable contract**:
- `wakeup.wake()` causes a currently-blocking or next `poll()` call to return.
- The wakeup itself does not produce a user-visible event (it is filtered by INV-6).
- `wake()` is safe to call after the driver is closed (benign errors are suppressed).
- `wake()` is safe to call concurrently from multiple threads.

**Platform mechanism**:
- kqueue: `EVFILT_USER` trigger event.
- epoll: write to `eventfd`.

## Naming

- Platform drivers extend the `Kernel` namespace: `Kernel.Readiness.Driver`,
  `Kernel.Completion.Driver`.
- Backend selection factory: `Kernel.Readiness.Backend.platformDefault()`,
  `Kernel.Completion.Backend.bestAvailable()`.
- Consumer writes `import Kernel`. No platform conditionals at the consumer level.

## swift-io / swift-sockets Boundary

**swift-io owns**: async byte transport capabilities.
- `IO.Reader`, `IO.Writer`, `IO.Stream` (with half-close), `IO.RandomAccess.Reader/Writer`.
- Cancellation, deadlines, backpressure contracts.
- Half-close is statically modeled: only `IO.Stream` (bidirectional) exposes
  `shutdown(.read)` / `shutdown(.write)`. Unidirectional types omit it.

**swift-sockets owns**: transport/protocol lifecycle.
- connect/listen/accept, addressing, TCP/UDP semantics, framing, socket options.

## Access Tiers

1. **Primary safe**: async I/O operations on safe buffer types.
2. **Advanced public**: lower-level but stable readiness/completion control.
3. **Transport SPI**: privileged hooks for swift-sockets.
4. **Expert/internal**: raw buffer interop and descriptor escape hatches.

## Buffer Design Target

- **Reads**: uniquely owned contiguous storage (`~Copyable`, no ARC). Enables zero-copy handoff.
- **Writes**: borrowed views (`Span<UInt8>` or `some Sequence<UInt8>`).
- **Advanced**: `UnsafeMutableRawBufferPointer` / `UnsafeRawBufferPointer` for zero-copy paths.
- Exact type is Phase 6. Design point (unique ownership + contiguous) is locked now.

## Migration Sequence

| Phase | Deliverable | Gate |
|-------|-------------|------|
| **0** | This document | Agreed architecture spec |
| **1** | Behavioral tests for 7 invariants | Tests pass on current code |
| **2** | Platform drivers in swift-darwin/linux/windows | Initially unused by swift-io |
| **3** | Port implementation under behavioral tests | Phase 1 tests pass unchanged |
| **4** | `Kernel.Readiness.Driver` + `Kernel.Completion.Driver` in swift-kernel | Backend factories work |
| **5** | Rewire swift-io to consume Kernel drivers | Current public API (Channel, Selector) intact |
| **6** | Public API redesign: IO.Reader/Writer/Stream | Architecture correction separated from API churn |

## Constraints

- **Swift 6.3** (swiftlang-6.3.0.123.5). `~Copyable` tuples not supported. Closures
  cannot capture `~Copyable` values.
- **`@_optimize(none)` SIL crash** on Unbounded channel. Known workaround; revisit on 6.4+.
- **MoveOnlyAddressChecker bug**: `Registration.Waiter` is a class workaround. Revisit on 6.4+.
- **3 split tests disabled** (cancellation propagation through `Cell.take()` -- unrelated).
- **Multi-package refactor**: Phases 2-5 touch swift-darwin, swift-linux, swift-windows,
  swift-kernel, and swift-io. Coordinate across monorepos.
