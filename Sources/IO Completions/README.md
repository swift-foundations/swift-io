# IO Completions

The **proactor** strategy of swift-io. One OS thread submits operations
to the kernel and reaps completions. A single `IO.completions(on:)`
factory turns that thread into a platform-agnostic `IO` witness.

This target is **delegation-first**: it consumes `Kernel.Completion`
directly and adds L3 composition (Actor, Entry table, multi-CQE cancel
handshake). There is no wrapper witness between the IO layer and the
kernel. Zero `@_spi(Syscall)`. Zero platform knowledge.

---

## 1. What this target provides

A consumer writes:

```swift
let actor = try IO.Completion.Actor()
let io = IO.completions(on: actor)

var buffer = [UInt8](repeating: 0, count: 4096)
let n = try await buffer.withUnsafeMutableBytes { bytes in
    try await io.read(from: fd, into: .init(bytes))
}
```

`io` is the same `IO` witness produced by every swift-io strategy. What
distinguishes this target is *how* those closures resolve: instead of
blocking-syscall + dedicated thread (Blocking) or non-blocking syscall +
readiness event (Events), each operation is **submitted to the kernel
as a work item** (io_uring SQE / IOCP overlapped request) and the
caller suspends until the kernel posts a completion (CQE / IOCP
completion packet).

Platform support:
- **Linux** (kernel 5.1+): io_uring via `liburing`.
- **Windows** (future phase): IOCP.
- **Darwin**: unsupported. Use `IO.events()` (kqueue) instead.

---

## 2. Vertical stack

| Layer | Package | Module | Owns | Key symbols |
|-------|---------|--------|------|-------------|
| **L1 Primitives** | `swift-kernel-primitives` | Kernel Completion Primitives | Completion vocabulary: `Kernel.Completion` resource, `.Driver` witness, submission, event, token, error | `Kernel.Completion`, `.Driver`, `.Event`, `.Submission`, `.Token`, `.Error` |
| **L2 Standards** | `swift-linux-standard` | Linux Kernel IO Uring Standard | io_uring SQE/CQE ABI encoding | `Kernel.IO.Uring`, `.Submission.Entry`, `.Completion.Entry` |
| **L3 Foundations** | `swift-kernel` | Kernel Completion | Platform unification: `.platform()` dispatch | `Kernel.Completion.platform()`, `.iouring()` |
| **L3 Foundations** | `swift-executors` | Executors | `Kernel.Thread.Executor.Completion` — owns OS thread, job queue, kernel resource, tick loop | `Kernel.Thread.Executor.Completion` |
| **L3 Foundations** | `swift-io` | **IO Completions (this target)** | Proactor runtime (Actor + Entry table); cancel handshake; `IO.completions(on:)` factory | `IO.Completion.Actor`, `.Entry`, `.Cancellation` |
| **L3 Foundations** | `swift-io` | IO Core | Strategy-agnostic `IO` witness + `IO.Error` | `IO`, `IO.Error` |

Platform conditionals (`#if os(...)`) live in **one** place:
`Kernel.Completion.platform()` in swift-kernel. IO Completions has zero
platform code; `IO+Completions.swift` is `#if os(Linux)`-guarded at the
factory level because the Darwin path is unsupported.

---

## 3. Source files

`IO.Completion` IS `Kernel.Completion` (typealias). Everything below is
an extension on the kernel type or a new nested type defined here.

| File | Type | Role |
|------|------|------|
| `IO.Completion.swift` | `IO.Completion` (typealias) | Namespace adoption: `IO.Completion = Kernel.Completion`. All nested types inherited from the kernel layer. |
| `IO+Completions.swift` | `IO.completions(on:)`, `IO.completions()` | Witness factories. Linux-only guard. |
| `IO.Completion.Actor.swift` | `IO.Completion.Actor` | Public actor pinned to `Kernel.Thread.Executor.Completion`. Owns the entries table, op-ID counter, submit/dispatch paths, and the multi-CQE cancel handshake. |
| `IO.Completion.Actor.Handle.swift` | `IO.Completion.Actor.Handle` | Weak back-reference from the tick closure to the actor, breaking the init-order cycle per [IMPL-083]. |
| `IO.Completion.Entry.swift` | `IO.Completion.Entry` | `~Copyable` in-flight record. Holds all per-operation state: submission parameters, dup'd descriptor, cancel flag, and continuation. The entries dictionary is the sole correlation and lifetime mechanism. |
| `IO.Completion.Cancellation.swift` | `IO.Completion.Cancellation` | Atomic flag shared between `onCancel` handler (any thread) and the dispatch path. |
| `exports.swift` | — | Module exports (`IO_Core`, `Async`). |

### What is NOT in this target

- **No `IO.Completion.Storage`** — Entry is the sole in-flight record. No class wrapper, no `Unmanaged.passRetained`, no retained-pointer custody.
- **No `IO.Completion.Loop`** — The actor owns the executor (`Kernel.Thread.Executor.Completion`) directly. The executor runs the tick loop; the actor provides the isolated dispatch body.
- **No `IO.Completion.Operation`** — Operations are constructed inline in the actor's witness methods (read, write, ready).
- **No `IO.Completion.Outcome` / `Success`** — Raw `Kernel.Completion.Event` is passed through. The consumer interprets via `event.result.failure` and `event.result.value!`.
- **No `IO.Completion.Driver` / `Handle` / `Capabilities`** — Deleted. The actor consumes `Kernel.Completion` directly.
- **No `IO.Completion.Error`** — Factories throw `Kernel.Completion.Error`. Runtime operations throw `IO.Error`.
- **No `IO.Completion.Wakeup.Channel`** — Deleted.

---

## 4. The core insight: proactor semantics

The reactor (Events) model is **readiness-then-syscall**: wait for the
kernel to say "this fd is readable," then issue `read`. The proactor
(Completions) model is **submit-then-await-completion**: hand the
operation to the kernel with a buffer pointer, suspend, resume when the
kernel returns the result.

The actor is pinned to the executor via `unownedExecutor`. Every actor
method (submit, cancel, query) runs on the executor's OS thread — same
co-location property as IO Events.

The executor's tick calls `assumeIsolated` to reach actor-isolated state
from the synchronous executor thread (SE-0424 bridge via
`isIsolatingCurrentContext`). The tick dispatches CQEs to waiting
entries.

### The Entry table

`Actor.entries: Dictionary<Kernel.Completion.Token, IO.Completion.Entry>`
is the sole correlation and lifetime mechanism. Each in-flight
operation owns exactly one entry, keyed by a counter-based token
(the same token passed as the submission's correlation ID). The entry
holds:

- Submission parameters (opcode, buffer address/length, offset, interest).
- The dup'd `Kernel.Descriptor` (~Copyable — closed on entry consumption).
- A `Cancellation` flag (checked when the CQE arrives).
- The suspended `CheckedContinuation<Kernel.Completion.Event?, Never>`.

Entry lifecycle:

```
submit()  ->  entries[token] = entry  ->  (kernel processes operation)  ->
    CQE arrives (token match)  ->  check cancel flag  ->
    entry.resolve(with: event)  [or .resolveAsCancelled()]  ->
    continuation.resume(returning: event)  [or nil]
```

The continuation carries the event directly — no side-channel result
slot. `nil` means cancelled; `.some(event)` means the kernel completed
the operation. The consumer's `mapEvent` closure interprets the raw
event.

Entries survive in the dictionary until the CQE arrives. This keeps the
dup'd descriptor alive across the kernel's custody window (SQE
submission through CQE consumption). No retained-pointer mechanism is
needed — the dictionary IS the lifetime manager.

### Contrast with IO Events

| | IO Events | IO Completions |
|---|---|---|
| Per-call state | Transient `Async.Channel.Unbounded` | Long-lived `Entry` in `entries` dict |
| Wakeup correlation | Broadcast to all senders on `Registration` | Exact token match in `entries` |
| Cancellation | Channel closure | Multi-CQE handshake via cancel SQE |
| Kernel work | Non-blocking syscall after readiness event | Kernel owns the op for its full duration |
| Buffer ownership | Caller owns; single syscall bounds access | Caller MUST keep the pointer stable until CQE |

---

## 5. The read path, end to end

A complete trace of `try await io.read(from: fd, into: buffer)`:

1. **Consumer** calls the `IO` witness; forwards to
   `IO.Completion.Actor.read(from:into:)`.

2. **Actor runs on the executor thread** (via `unownedExecutor`):
   - `generateID()` — fresh operation ID from the monotonic counter.
   - Dups the fd via `Kernel.Descriptor.Duplicate.duplicate(fd)`.

3. **`awaitOperation`** — the cancellation-aware submission helper:
   - Creates `Cancellation` flag and `CancelCoordinator`.
   - Enters `withTaskCancellationHandler` + `withCheckedContinuation`.
   - Inside the continuation body (synchronous, on executor thread):
     constructs the `Entry` (consuming the dup'd descriptor), builds a
     `Kernel.Completion.Submission`, and calls `submit()`.
   - `submit()` borrows the descriptor from the entry for the kernel
     call, then stores the entry in the dictionary.

4. **Actor suspends**; the executor thread is free to run the next
   tick.

5. **Tick fires** — executor calls wait, dispatch:
   - `wait()` blocks on the kernel's notification mechanism (eventfd on
     Linux) until CQEs are available.
   - `dispatch(events)` iterates the CQE buffer. For each event:
     - Look up `entries[event.token]` (counter-based match).
     - If found and cancel flag is set: `entry.resolveAsCancelled()`.
     - If found and not cancelled: `entry.resolve(with: event)`.
     - Both paths resume the continuation.

6. **Awaiter resumes** on the executor thread.
   The continuation returns `Kernel.Completion.Event?`.
   `guard let event` — if `nil`, throw `IO.Error.cancelled`.
   `mapEvent(event)` extracts the bytes-read count (or rethrows as
   `IO.Error`).

7. **Return to the consumer** — an ordinary value return.

`write` and `ready` follow the same shape with different opcodes.
`close` does **not** submit an SQE — it calls
`Kernel.Close.close(consume fd)` directly, matching the other
strategies' local-syscall pattern.

---

## 6. Lifecycle and failure

### Descriptor ownership

For operations that carry a descriptor (read, write, poll), the actor
dups the fd before building the Entry. The Entry owns the dup'd fd
(~Copyable `Kernel.Descriptor`); its consumption (resolve or deinit)
closes it. The caller's original fd is unaffected.

### Buffer ownership

The kernel holds the pointer from SQE submission through CQE
consumption. On cancellation, the proactor MUST wait for both the
original CQE and the cancel CQE before returning — otherwise the
consumer's frame could release the buffer while the kernel still writes
into it. See `Research/io-proactor-buffer-ownership.md`.

### The multi-CQE cancel handshake

On `Task.cancel()`, `withTaskCancellationHandler`'s `onCancel` fires
from an arbitrary thread. The handshake:

1. `CancelCoordinator.tryBegin()` — atomic single-winner claim.
2. Winner sets the `Cancellation` flag and spawns a `Task` that:
   - Submits a cancel SQE for the target ID.
   - Awaits its CQE (reusing the same submission path).
   - `markCancelCQEReceived()` — opens the coordinator's gate.
3. Meanwhile, the original CQE arrives (possibly with -ECANCELED).
   `dispatch()` sees the entry's cancel flag is set and resolves
   as cancelled. The continuation resumes.
4. Stage 2 — if `coord.isCancelled`, await `coord.waitForCancelCQE()`.
   The outer `await` returns only after both CQEs have been
   processed (buffer-ownership safety).

`CancelCoordinator` is a reference type specifically because
`@Sendable` `onCancel` closures cannot capture actor-isolated or inout
value types. Do not collapse this into a value type.

### Shutdown

`IO.Completion.Actor.deinit` calls `completion.shutdown()` which sets
the halt flag, wakes the poll thread, and joins it. The
`Kernel.Completion` resource is closed (munmap / ring fd close). Any
in-flight entries are resolved as cancelled by `cleanup()`.

### Error mapping

Two translations (both in `IO.Completion.Actor.swift`):

- `Kernel.Descriptor.Duplicate.Error -> IO.Error`
- `Kernel.Error -> IO.Error`

`Kernel.Completion.Error` surfaces directly from `IO.Completion.Actor.init`
and `IO.Completion.Actor.shared()`.

---

## 7. Relationship to the other strategies

swift-io offers three strategies with identical witness shape:

| Strategy | Kernel mechanism | Thread model |
|----------|------------------|--------------|
| `IO.blocking` | Blocking POSIX syscalls | Dedicated worker threads |
| `IO.events` | kqueue / epoll, non-blocking + readiness | One reactor thread (actor is the loop) |
| **`IO.completions`** | io_uring (Linux 5.1+), IOCP (future) | One proactor thread (actor pinned to executor) |

Shape parallel:

| | Fresh instance | Shared instance |
|--|---------------|-----------------|
| Events | `try IO.Event.Actor()` | `try IO.Event.Actor.shared()` |
| Completions | `try IO.Completion.Actor()` | `try IO.Completion.Actor.shared()` |

---

## 8. Summary

**IO Completions is legitimately more complex than IO Events because
the proactor paradigm requires things the reactor paradigm does not:**
an Entry table keyed by correlation token, the multi-CQE cancel
handshake, and buffer-ownership safety across the kernel's custody
window. These are proactor-intrinsic and stay.

The module is 7 source files. No `@_spi(Syscall)`. No platform
knowledge. No retained-pointer custody. No intermediate wrapper types.
The actor IS the proactor runtime; the entries dictionary IS the
correlation and lifetime manager; the continuation carries the event
directly.
