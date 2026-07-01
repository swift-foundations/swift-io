# IO Events

The **reactor** strategy of swift-io. One OS thread multiplexes Swift
concurrency jobs, kernel readiness polling, and event dispatch. A single
`IO.events(on:)` factory turns that thread into a platform-agnostic `IO`
witness.

This document describes the conceptual model by walking the vertical stack
from user-facing strategy down to the raw syscall, then back up.

---

## 1. What this target provides

A consumer writes:

```swift
// Own reactor with default buffer size
let actor = try IO.Event.Actor()
let io = IO.events(on: actor)

// Tune the poll buffer for a high-connection server
let actor = try IO.Event.Actor(maxEventsPerPoll: 1024)

// Inject a custom source (test fake, or a specific platform backend)
let source = try Kernel.Event.Source.epoll(maxEvents: 1024)
let actor = IO.Event.Actor(source: consume source, maxEventsPerPoll: 1024)

// Or the process-shared reactor
let io = try IO.events()

let n = try await io.read(from: fd, into: buffer)
try await io.ready(from: listener, interest: .read)
let accepted = try Kernel.Socket.Accept.accept(listener)
```

`io` is the same `IO` witness produced by every swift-io strategy. The
value is a struct of `async throws(IO.Error)` closures (`IO.swift:133`).
What distinguishes this target is *how* those closures resolve: every call
is served by a non-blocking syscall armed by a kernel readiness event
(kqueue on Darwin, epoll on Linux).

`IO.Event.Actor` is a public actor — *the* event loop. There is no wrapper
struct between it and the consumer; the actor itself is the handle, the
executor owner, and the dispatch target.

---

## 2. Vertical stack

The target composes four layers. Each layer answers one question; no layer
encodes policy that belongs in another.

| Layer | Package | Module | Owns | Example symbol |
|-------|---------|--------|------|----------------|
| **L1 Primitives** | `swift-async-primitives` | Async Channel Primitives | Sync-send / async-receive channel, `~Copyable` element support | `Async.Channel<Element>.Unbounded` |
| **L1 Primitives** | `swift-kernel-primitives` | Kernel Event Primitives | Event vocabulary; `Driver` witness encoding registry / staleness / one-shot re-arm | `Kernel.Event`, `Kernel.Event.Driver`, `Kernel.Event.Source` |
| **L1 Primitives** | `swift-kernel-primitives` | Kernel Primitives Core | Cross-thread wakeup | `Kernel.Wakeup.Channel` |
| **L2 Standards** | `swift-darwin-standard` | Darwin Kernel Event Standard | kqueue(2) spec encoding (kevent, EVFILT_*, flags) | `Kernel.Event.Queue` (a.k.a. `Kernel.Kqueue`) |
| **L2 Standards** | `swift-linux-standard` | Linux Kernel Event Standard | epoll(7) + eventfd(2) spec encoding | `Kernel.Event.Poll`, `Kernel.Event.Descriptor` |
| **L3 Foundations** | `swift-kernel` | Kernel Event | **Unification.** `.platform()` dispatch; packs L2 into the L1 Driver witness | `Kernel.Event.Source.kqueue()`, `Kernel.Event.Source.epoll()` |
| **L3 Foundations** | `swift-executors` | Executors | One OS thread running drain-jobs → wait → dispatch | `Kernel.Thread.Executor.Polling` |
| **L3 Foundations** | `swift-io` | **IO Events (this target)** | Public actor that owns the Polling executor directly; per-call channel dispatch; `IO.events(on:)` factory | `IO.Event.Actor`, `IO.events(on:)` |

Platform conditionals (`#if os(...)`) live in exactly three files:
`Kernel.Event.Source.swift`, `+Kqueue.swift`, `+Epoll.swift` inside the
Kernel Event target of swift-kernel. Every layer above imports `Kernel` and
is unconditional.

---

## 3. Key types in this target

| File | Type | Role |
|------|------|------|
| `IO+Events.swift` | `IO.events(on:)`, `IO.events()` | Witness factories. Wire the four `IO` closures (`read`, `write`, `close`, `ready`) to forward onto the actor, plus `unownedExecutor` for consumer co-location. |
| `IO.Event.Actor.swift` | `IO.Event.Actor` | **The event loop.** Public actor that owns `Kernel.Thread.Executor.Polling` and exposes `unownedExecutor` pointing at it. Holds the registration and dispatch tables. Has `public init() throws(IO.Event.Failure)` and `public static func shared()`. Methods run on the Polling thread via actor isolation. |
| `IO.Event.Actor.Handle.swift` | `IO.Event.Actor.Handle` | Class-typed weak back-reference from the tick closure to the actor. Breaks the `[weak self]` init-order trap ([IMPL-083]). |
| `IO.Event.Actor.Registration.swift` | `IO.Event.Actor.Registration` | Per-driver-ID dispatch record. Holds the interest mask and a `Senders` bundle. |
| `IO.Event.Actor.Registration.Senders.swift` | `IO.Event.Actor.Registration.Senders` | Per-interest sender lists (`read` / `write` / `priority`) with broadcast-and-drain primitives (`append(_:for:)`, `drain(event:for:)`, `closeAll()`). |
| `IO.Event.Actor.State.swift` | `IO.Event.Actor.State` | Lifecycle flag: `.running` or `.shuttingDown`. |
| `IO.Event.Actor.RetryDecision.swift` | `IO.Event.Actor.RetryDecision` | Pure classifier for `Kernel.Event.Driver.Error` → `{retry, yieldAndRetry, halt}`, constructed via `init(for:)`. |
| `IO.Event.swift` | `typealias IO.Event = Kernel.Event` | Namespace adoption per [API-NAME-004a]: `IO` builds substantial behavior on the kernel event concept. All types under `IO.Event.*` (`ID`, `Interest`, `Options`, plus the L3-added `Actor`, `Error`, `Failure`) attach through this adoption. |
| `IO.Event.Error.swift` | `IO.Event.Error` | Leaf errors at the I/O boundary (platform code, half-close, descriptor state). |
| `IO.Event.Error+Source.swift` | `init(_:)` | Bridge from `Kernel.Event.Driver.Error`. |
| `IO.Event.Failure.swift` | `IO.Event.Failure` | `Async.Lifecycle.Error<IO.Event.Error>` — lifecycle-aware failure (adds `cancellation`, `shutdownInProgress`, `timeout`). |

---

## 4. The core insight: the actor IS the event loop

Every decision in this target follows from one structural choice:

> A **single** OS thread serves as
> (a) the `SerialExecutor` for `IO.Event.Actor`,
> (b) the poll thread blocking in `kevent` / `epoll_wait`, and
> (c) the dispatcher that fans poll results into per-call channels.

That thread is owned by `Kernel.Thread.Executor.Polling`
(`Kernel.Thread.Executor.Polling.swift:90`). Its run loop is a fixed schedule:

```
loop:
    drain actor jobs                       ← (a) serial execution
    wait on Kernel.Event.Source (blocking) ← (b) kernel readiness
    tick(events)                           ← (c) dispatch
    repeat until shouldHalt
```

`IO.Event.Actor` **owns the executor directly** — no intermediate `Loop`
class, no wrapper struct. The actor's `polling` property IS the event
loop; the tick closure reaches back into actor-isolated state via
`assumeIsolated`. Actor methods are pinned to that same thread via
`unownedExecutor = polling.asUnownedSerialExecutor()`
(`IO.Event.Actor.swift:81`).

### The Handle weak-box (init-order trap)

`Polling.init` installs the tick closure at construction time, which
creates a chicken-and-egg with `[weak self]`: `self` cannot be captured
(even weakly) until every stored property is initialised, but
`self.polling` IS the property being initialised by the expression that
contains the tick closure.

The bridge (`IO.Event.Actor.Handle.swift:31`) is a local class with
`weak var actor: IO.Event.Actor?`:

```swift
public init() throws(IO.Event.Failure) {
    let source = try ...                        // platform event source
    let handle = Handle()                       // local, not `self`
    self.polling = Polling(source: source) { wait in
        guard let actor = handle.actor else { return .halt }  // weak deref
        // ... wait() then actor.assumeIsolated { ... }
    }
    handle.actor = self                         // sequenced AFTER polling init
}
```

When the actor deinits, Swift nils out the weak ref; the next tick returns
`.halt`, the Polling thread exits, and `polling.shutdown()` (in actor
deinit) joins it. This is the reference implementation of [IMPL-083].

### The `assumeIsolated` + region-transfer pattern

The tick closure runs synchronously on the Polling thread, outside any
Swift Task context. Reaching actor-isolated state from sync code requires
`assumeIsolated` + Polling's `isIsolatingCurrentContext()` override — the
latter confirms the calling thread IS the executor's thread, letting the
runtime skip the task-local check.

Subtle constraint: `wait()` MUST be called *outside* `assumeIsolated`. The
task-isolated `wait` thunk triggers a region-analysis sending error if
captured into an actor-isolated closure, even though both run on the same
OS thread. Values cross into the isolated closure via region transfer —
`events` / error in a disconnected region, never touched after transfer
(`IO.Event.Actor.swift:110-128`).

### Consequences

- **No locks on the hot path.** The actor's `registrations` table and the
  Driver's internal registry are both thread-confined.
- **No cross-thread hop between readiness signal and syscall retry.** When
  a read waiter resumes, the retry happens on the same thread that
  produced the event.
- **Consumer co-location.** A consumer actor that forwards its own
  `unownedExecutor` to this witness elides every per-call executor hop —
  the TCA26 shared-executor pattern (`IO.swift:246` documents this).

The only *cross*-thread entry points are:

- `enqueue(_:)` on the executor (thread-safe via an internal mutex; wakes
  the poll thread via `Kernel.Wakeup.Channel.wake()`).
- `Async.Channel.Unbounded.Sender.send(...)` from the Polling thread to an
  awaiter suspended on a different thread.

---

## 5. Kernel Event — the unification layer

`Kernel Event` in swift-kernel is where L2 platform specs become a single L1
witness.

### 5a. The cross-platform vocabulary (L1)

`Kernel.Event` is a plain value with three fields (`Kernel.Event.swift:40`):

```swift
public struct Event: Sendable, Equatable {
    public let id: ID              // Tagged<Kernel.Event, UInt>
    public let interest: Interest  // .read | .write | .priority
    public let flags: Options      // .error | .hangup | .readHangup | .writeHangup
}
```

`Interest` is a typealias of `Kernel.Descriptor.Interest`
(`Kernel.Event.Interest.swift:22`) — reactor-style readiness and
proactor-style completions (swift-io's `IO Completions` target) share the
same vocabulary word, with neither paradigm "owning" it.

### 5b. The Driver witness (L1)

`Kernel.Event.Driver` (`Kernel.Event.Driver.swift:30`) is a `~Copyable`
struct of closures:

```swift
public struct Driver: ~Copyable {
    let _register:   (consuming Kernel.Descriptor, Interest) throws(Error) -> ID
    let _modify:     (ID, Interest) throws(Error) -> Void
    let _deregister: (ID) throws(Error) -> Void
    let _arm:        (ID, Interest) throws(Error) -> Void
    let _poll:       (Kernel.Time.Deadline?, inout [Kernel.Event]) throws(Error) -> Int
    let _close:      () -> Void
}
```

Its `init` (`Kernel.Event.Driver.swift:91`) takes *backend* closures
(`add`, `modify`, `remove`, `arm`, `poll`, `close`) and wraps them with:

- **ID generation** — a plain counter over a thread-confined `Shared` class.
- **Registry** — `Dictionary<ID, Registration>` tracking descriptor,
  interest, `armedInterest`. `Registration` is `~Copyable`; its deinit
  closes the dup'd fd.
- **Staleness suppression** — after a poll, the Driver compacts the result
  buffer in place, dropping any event whose registration has since been
  removed (e.g. the fd was closed between `_poll` and `_deregister`).
- **One-shot re-arm** — after delivering the portion of `armedInterest`
  that fired, the Driver silently re-arms the residual so a half-duplex
  event (e.g. `[.read, .write]` armed, only `.read` fires) does not
  starve the other direction.

Crucially, the Driver is **not `Sendable`**. It is moved to the poll thread
via `sending` and thereafter thread-confined. No synchronization is needed
in any of its closures.

### 5c. The factory (L3)

`Kernel.Event.Source.platform()` (`Kernel.Event.Source.swift:19`) is the
platform conditional:

```swift
public static func platform() throws(Kernel.Event.Driver.Error) -> Kernel.Event.Source {
    #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
        try .kqueue()
    #elseif os(Linux)
        try .epoll()
    #endif
}
```

The two backend factories (`+Kqueue.swift`, `+Epoll.swift`) each pack their
L2 spec (kevent / epoll_event) into the shared `Driver` constructor. The
Darwin backend translates one `Kernel.Event.Interest` into two kevents
(one per filter); the Linux backend translates it into a single epoll mask
using `Kernel.Event.Poll.Events(interest:)`
(`Linux.Kernel.Event.Poll.Events+Interest.swift:48`). After normalisation,
both backends produce `Kernel.Event` records that are indistinguishable
from above.

The backend factories document seven **policy invariants** in-file. Each
invariant lives in exactly one designated location:

| Invariant | Where it's enforced |
|-----------|---------------------|
| INV-1 Registration Identity | `Driver.init` (counter) |
| INV-2 Ownership Lifecycle | `Driver.init` (registry owns dup'd fd) |
| INV-3 Delta Correctness | backend `modify` closure (kqueue set-diff; epoll full replace) |
| INV-4 One-Shot Re-Arm | backend `add` + `arm` closures (`EV_DISPATCH` / `EPOLLONESHOT`) |
| INV-5 Normalization | backend `poll` closure (raw → `Kernel.Event`) |
| INV-6 Staleness Suppression | `Driver.init` (in-place compaction by registry membership) |
| INV-7 Wake Responsiveness | backend factory (`EVFILT_USER` / eventfd registered upfront) |

This is the **layered principle in practice**: cross-platform policy that
would otherwise be duplicated across Darwin and Linux code paths is
absorbed into the L1 Driver; platform-specific translation stays at L3.

---

## 6. The witness cascade

There are three witnesses stacked vertically. Each narrows the interface
and adds policy; none duplicates what another owns.

| # | Witness | Layer | What it abstracts over | Policy added |
|---|---------|-------|------------------------|--------------|
| 1 | `Kernel.Event.Driver` | L1 | kqueue vs. epoll (vs. future IOCP) | ID generation, registry, staleness suppression, one-shot re-arm |
| 2 | `Kernel.Event.Source` | L1 | resource lifetime + wakeup | `~Copyable` ownership, `Sendable` wakeup split |
| 3 | `IO` | L3 (IO Core) | reactor vs. blocking vs. completions | async boundary, `IO.Error` taxonomy, `unownedExecutor` binding |

A reader who wants to add a Windows backend edits one file (a new
`Kernel.Event.Source+IOCP.swift`) that constructs a Driver from IOCP
primitives. Everything above that file remains unchanged.

A reader who wants a different async strategy (e.g. the proactor in
`IO Completions/`) implements a different `IO.*.Actor` and factory; the
Driver witness is unused. That is why `Kernel.Event.Source` holds no
opinion about async, threading, or channels.

---

## 7. Role of `Async.Channel` — per-call, not per-fd

This is the architectural detail most likely to surprise. The reactor does
NOT hold a long-lived receiver per fd. It holds a *list of senders* per
interest, and every `io.ready` / `io.read` (on EAGAIN) / `io.write` (on
EAGAIN) creates a **transient** `Async.Channel.Unbounded`.

```
Registration (for a driver-assigned Kernel.Event.ID)
    └── senders: Senders
        ├── read:     [Async.Channel<Kernel.Event>.Unbounded.Sender]
        ├── write:    [Async.Channel<Kernel.Event>.Unbounded.Sender]
        └── priority: [Async.Channel<Kernel.Event>.Unbounded.Sender]

Each awaiter (local to a call)
    └── Receiver (~Copyable, single-use)
```

### The flow per await

```swift
// Inside IO.Event.Actor.wait(for:interest:)
var channel = Async.Channel<Kernel.Event>.Unbounded()
registrations[id]?.senders.append(channel.sender, for: interest)
arm(id: id, interest: interest)
let ends = (consume channel).take().ends()             // consume → ~Copyable Ends
_ = try await ends.receiver.receive()                  // suspend on OUR receiver
```

When the kernel signals readiness, `dispatch` calls
`Registration.Senders.drain(event:for:)` once per interest bit. Each
`drain` call either does nothing (bit not set) or projects a
direction-specific event, broadcasts it to every sender in the matching
list, then **drains the list**. The receivers — one per awaiter —
resume independently.

### Why per-call, not per-fd

The single-suspended-receiver precondition of `Async.Channel.Unbounded`
(one awaiter at a time on a given receiver) is satisfied **structurally** —
each awaiter has its own receiver; none is shared. A concurrent
`io.ready(.read)` and `io.read(fd)` arising on the same fd produce two
channels with two independent receivers, both subscribed to the same
`senders.read` list. The kernel's one-shot `[.read]` event fires once
and resolves both.

Contrast with the per-fd alternative: one long-lived receiver per (fd,
interest), reused across all awaiters. That shape cannot handle two
concurrent waiters on the same direction without violating the
single-suspender precondition. The per-call pattern is what makes
concurrent `io.ready` on the same fd safe.

### Why Unbounded

- `Sender.send(...)` is **synchronous**. The Polling thread cannot suspend
  while dispatching — it must fan out without yielding the run loop.
- `Receiver.receive()` is **async**. The waiter resumes when an event
  arrives, or observes `nil` if the sender was closed (shutdown).
- `Sender` is `Copyable`; `Receiver` is `~Copyable`. That shape matches
  the asymmetry exactly: many dispatch sites (any awaiter might append),
  at most one awaiter per receiver (enforced by the type).

### One-shot separation per interest direction

`dispatch` invokes `Senders.drain(event:for: .read)`,
`Senders.drain(event:for: .write)`, and `Senders.drain(event:for: .priority)`
independently. If both `.read` and `.write` fire in one kernel event, the
record is split: read-senders receive a `.read`-only event, write-senders
receive a `.write`-only event. This matters because one-shot re-arm is
per-direction — a half-duplex workload must not forfeit the other half.

The Unbounded channel is defined in
`swift-async-primitives/Async.Channel.Unbounded.swift:59`. It uses a
coroutine-based `Mutex` inside, but the relevant contract at this layer
is the sync-send / async-receive split.

---

## 8. The read path, end to end

A complete trace of `try await io.read(from: fd, into: buffer)`:

1. **Consumer** calls the `IO` witness. The closure forwards to
   `IO.Event.Actor.read(from:into:)` (`IO+Events.swift:29`).

2. **Actor, first call for this fd.** `register(fd)` runs on the Polling
   thread via actor isolation:
   - Compute the identity key: `Kernel.Event.ID(descriptor: fd)`.
   - If already in `registeredIDs` → return the existing driver ID.
   - Otherwise: `dup` the fd (the driver owns its own copy), then
     `polling.source.register(descriptor:, interest: [.read, .write])`
     → `Kernel.Event.ID`. Registering both directions upfront means
     subsequent reads and writes never re-register.
   - Insert an empty `Registration` (its `Senders` defaults to three
     empty lists) and record the mapping.

3. **Actor attempts the syscall.**
   `Kernel.IO.Read.read(fd, into: buffer.base.nonNull)` runs synchronously
   on the Polling thread. The fd is non-blocking (precondition of the
   reactor strategy). The call returns either:
   - `n >= 0` bytes: the actor returns `n`.
   - `throws .blocking(.wouldBlock)` (EAGAIN / EWOULDBLOCK): proceed to
     step 4.

4. **Arm and suspend.** `wait(for:interest:)`:
   - Create a transient `Async.Channel.Unbounded`.
   - `registrations[id]?.senders.append(channel.sender, for: .read)`.
   - `polling.source.arm(id:, interest: .read)` — re-enables one-shot
     delivery for the read direction.
   - `consume` the channel → extract `Ends`.
   - `await ends.receiver.receive()` — the actor suspends. Because the
     actor's executor is Polling, "suspending" means yielding the thread
     back to the Polling run loop.

5. **Poll thread runs.** The Polling run loop (same OS thread) enters
   `waitSource.wait(...)` which blocks in `kevent` / `epoll_wait`. The
   kernel eventually wakes it with a readiness record.

6. **Dispatch.** The tick closure:
   - Calls `wait()` outside `assumeIsolated`, catching either an events
     buffer or a `Kernel.Event.Driver.Error`.
   - Enters `actor.assumeIsolated { isolatedSelf in ... }`. Inside:
     - Success path: `dispatch(events)` iterates each event and calls
       `Senders.drain(event:for: .read)`, `.write`, `.priority` on the
       matching registration. Each `drain` broadcasts to every sender on
       its list and drains the list.
     - Error path: `RetryDecision(for: error)` applies the policy inline:
       EINTR → retry, ENOMEM → yield-then-retry, EAGAIN → retry,
       everything else → `cleanup()` (close every sender in every
       registration so awaiters observe shutdown) + halt.

7. **Awaiter resumes.** `receiver.receive()` returns an
   `Optional<Kernel.Event>` (`nil` means the channel was closed — the
   reactor is shutting down). Non-nil means readiness was signalled.

8. **Retry the syscall.** Back in the actor's `while true` loop,
   `Kernel.IO.Read.read(...)` is attempted again. It either succeeds or
   throws `.blocking(.wouldBlock)` again (rare but possible under
   edge-triggered semantics); in that case the loop appends a new sender,
   arms, and awaits once more.

`write` and `ready` follow the same shape. `ready` is the readiness-only
composition primitive: it does not attempt a syscall — it is the hook for
protocols (e.g. `Kernel.Socket.Accept.accept`) that need "wait for
readiness, then issue a syscall the `IO` witness does not expose".

---

## 9. Lifecycle and failure

### Registration ownership

The descriptor passed to `io.read` is borrowed. The actor immediately
`dup`s it so the driver owns an independent fd whose close-time is
controlled by the driver's `Registration` deinit (not the caller's
lifecycle). This is the ownership lifecycle invariant (INV-2).

### Close

`io.close(fd)` delegates to `deregister(_:)` and then closes the fd:

1. `deregister(descriptorID)`:
   - Looks up and removes the driver ID via
     `registeredIDs[descriptorID]`.
   - Removes the `Registration` and calls `Senders.closeAll()` — any
     pending `receive()` observes `nil` and surfaces as
     `IO.Event.Failure.shutdownInProgress`.
   - `polling.source.deregister(id:)` — the driver's staleness
     suppression drops any already-queued poll results for this id.
2. `Kernel.Close.close(consume fd)` closes the caller's original fd.
   Errors are swallowed (same policy as the blocking strategy).

### Shutdown

`IO.Event.Actor` does not expose shutdown — its lifetime follows its
owners. The actor's `deinit` calls `polling.shutdown()`, which sets the
halt flag, wakes the poll thread via `Kernel.Wakeup.Channel`, and joins
(or detaches if called from the executor's own thread). The tick's
`handle.actor` weak ref has already been nilled by Swift at the moment of
deinit, so the next tick (if any) returns `.halt` immediately.

### Error mapping

Errors flow upward via two transformations:

- `Kernel.Event.Driver.Error` → `IO.Event.Error`
  (`IO.Event.Error+Source.swift:8`): a direct case-for-case mapping plus
  the reactor-specific additions (`alreadyRegistered`, `deregistered`,
  half-close flags).
- `IO.Event.Failure` → `IO.Error`
  (in `IO.Event.Actor.swift` as a `@usableFromInline` helper): lifecycle
  wrapper collapse — `.cancellation` → `.cancelled`,
  `.shutdownInProgress` → `.shutdown`, `.failure(...)` →
  `.platform(...)` or `.brokenPipe`. This is the strategy-agnostic
  taxonomy consumers see.

---

## 10. What this target does NOT own

- **Platform conditionals.** Lives in swift-kernel / Kernel Event only.
- **Raw syscall shapes.** `Kernel.Event.Queue`, `Kernel.Event.Poll`, and
  `Kernel.Event.Descriptor` are the faithful L2 encodings. `IO Events`
  never imports them.
- **Event vocabulary.** `Kernel.Event`, `Interest`, `Options`, `ID` are
  L1. `IO.Event` is a `typealias` to `Kernel.Event`, a namespace
  adoption (per [API-NAME-004a]), not a re-definition.
- **Async channel mechanics.** The single-suspended-receiver semantics,
  the sync-send / async-receive split, and the `~Copyable`-safe storage
  all live in `Async.Channel` primitives.
- **Thread-local machinery.** The single-thread run loop,
  mutex-protected job queue, wakeup signalling, and
  `isIsolatingCurrentContext()` for the Swift concurrency runtime are
  `Kernel.Thread.Executor.Polling`.

What remains — and is the exclusive contribution of this target — is
**the assembly**: how to pin the public `IO.Event.Actor` to the Polling
executor without a `[weak self]` init trap, how to fan poll results into
per-call async channels, how to retry the syscall on readiness, and how
to present the result as the strategy-agnostic `IO` witness.

---

## 11. Relationship to the other strategies

swift-io offers three strategies with identical witness shape:

| Strategy | Kernel mechanism | Thread model |
|----------|------------------|--------------|
| `IO.blocking` | Blocking POSIX syscalls | Dedicated worker threads (an `IO.Blocking.Lane`) |
| **`IO.events`** | kqueue (Darwin) / epoll (Linux), non-blocking + readiness | One reactor thread |
| `IO.completions` | io_uring (Linux 5.1+), proactor submission + CQE | One reactor thread (proactor style) |

The `IO` witness (`IO.swift:133`) is strategy-agnostic. A consumer can
swap strategies without touching protocol code. The
`ready(from:interest:)` operation exists precisely so that
readiness-based composition (e.g. "wait for accept-ability, then issue
`accept`") is expressible against the witness without the witness having
to grow a full socket API.

Shape parallel with the other strategies:

| | Fresh instance | Shared instance |
|--|---------------|-----------------|
| Blocking | `IO.Blocking()` | `IO.Blocking.shared` |
| **Events** | `try IO.Event.Actor()` | `try IO.Event.Actor.shared()` |
| Completions | `try IO.Completions()` | `try IO.Completions.shared()` |

Events is the one strategy that fully collapsed its public handle into
the actor itself — no intermediate struct. Blocking is a struct with a
stored executor pool; Completions is still a struct wrapping an internal
actor. A parallel Events-style collapse of Completions is a plausible
follow-up.

---

## 12. Summary

`IO Events` is a thin L3 assembly. The heavy design work lives below it:

- **L1** supplies the vocabulary (`Kernel.Event`) and the witness
  (`Kernel.Event.Driver`) that encodes cross-platform policy in one
  place.
- **L2** supplies the faithful platform encodings (kqueue, epoll,
  eventfd).
- **L3 Kernel Event** unifies L2 into the L1 witness with a `.platform()`
  factory — the only place in the stack where `#if os(...)` appears.
- **L3 Executors** contributes `Kernel.Thread.Executor.Polling`, a
  single-thread executor that can be driven by any `Kernel.Event.Source`.
- **L3 IO Events** (this target) is `IO.Event.Actor` — a public actor
  that owns a Polling executor directly, uses the Handle weak-box to
  break the init-order trap, fans kernel events into per-call async
  channels with broadcast-and-drain dispatch, and is exposed to
  consumers through the strategy-agnostic `IO` witness via
  `IO.events(on:)`.

The result is readiness-based non-blocking I/O where each layer owns one
concern, no policy is duplicated across platforms, and the hot path —
actor method, arm, suspend, kernel wait, dispatch, resume, retry — runs
on a single thread with no lock on the registration table, the dispatch
list, or the driver registry.
