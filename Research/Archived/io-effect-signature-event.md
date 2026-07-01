# Σ_Event — Effect Signature

> **CORRECTIVE BANNER (2026-04-20)**: This note overshot. It elaborates
> handler-internal operations (`register`, `wait`, `modify`,
> `unregister`) into prose that reads like a public algebra spec. The
> **public Σ_IO is the four operations on `IO`**: `read`, `write`,
> `close`, `ready` (see `Sources/IO Core/IO.swift:133` and
> `Research/README.md`). The operations described below live inside
> `IO.Event.Actor` and are not consumer-facing. They are reference
> material for handler authors only. The actual cross-platform witness
> at L1 is `Kernel.Event.Driver` (see
> `Sources/IO Events/README.md` §5b for the real shape).

<!--
---
version: 1.0.0
created: 2026-04-20
status: DRAFT
purpose: |
  Per-component signature note for the Event (readiness / reactor)
  sub-theory of Σ_IO. Enumerates operations, types, and equational
  obligations on handlers.

basis: io-algebraic-effects-foundation.md §6.2, swift-io-thesis.md §3.2
---
-->

## 1. Position

Σ_Event captures the **reactor** paradigm: the kernel notifies the
program when a file descriptor becomes ready for an operation
(`POLLIN`, `POLLOUT`, etc.); the program then performs the operation
itself, in user-space, on a non-blocking descriptor.

Σ_Event is one of two execution paradigms in Σ_IO. The other is
Σ_Completion (proactor). They are independent sub-signatures; a
single program may use both via coproduct.

## 2. Operations

```
register[Phase=Initial] :
  (FileDescriptor, ReadinessMask) → Token[Registered]

modify[Phase=Registered] :
  (Token[Registered], ReadinessMask) → Token[Registered]

wait :
  Token[Registered] → ReadinessSet

unregister[Phase=Registered] :
  Token[Registered] → Token[Deregistered]
```

The phase parameter encodes typestate: a token can only have
operations applied that are valid in its current phase. This is a
Swift surface refinement of the bare algebraic signature; the
underlying operations are unchanged.

## 3. Types

| Symbol | Concrete Swift |
|--------|----------------|
| `FileDescriptor` | `Kernel.FileDescriptor` |
| `ReadinessMask` | `IO.Event.Mask` (OptionSet of `.read`, `.write`, `.error`, `.hangUp`) |
| `Token[Phase]` | `IO.Event.Token<Phase>` (~Copyable, typestate-tagged) |
| `ReadinessSet` | concrete subset of `ReadinessMask` returned by `wait` |

## 4. Equational laws (E_Event)

### 4.1 Register-unregister inverse
```
register(fd, m) >>= λt.
  unregister(t)
  ≡
return ()
```
A register immediately followed by unregister is observationally
equal to no-op (modulo any registration side effect on the
descriptor itself).

### 4.2 Modify monotonicity
```
register(fd, m) >>= λt.
  modify(t, m')
  ≡
register(fd, m')                         -- new mask supersedes old
```
The most recent mask wins. Prior wait results may have been
generated under the old mask; only future waits see the new mask.

### 4.3 Wait-after-unregister
```
unregister(t); wait(t)   ≡   throw IO.Event.Error.tokenNotRegistered
```
Waiting on a deregistered token is an error, not a deadlock and not
a silent success. The typestate phase parameter prevents this at
compile time, but the equation must hold for any code path that
elides the typestate check (e.g. via `any Token`).

### 4.4 Spurious wakeup tolerance
```
wait(t)   may return ∅                  -- empty ReadinessSet
```
The handler is permitted to wake the caller with an empty readiness
set (spurious wakeup). The caller must tolerate this and re-issue
`wait`. This is *not* an equation but a permission — it weakens the
caller's right to assume non-empty results.

### 4.5 Concurrent wait disallowed
```
async let r1 = wait(t)
async let r2 = wait(t)
   ≡   undefined behaviour
```
A token may be waited on by at most one task at a time. This is a
linearity constraint outside classical algebraic-effect theory; it
is enforced at the Swift surface by `~Copyable` Token.

## 5. Handler obligations

A handler `H_Event` for Σ_Event must:

1. Maintain a kernel-side registration table (kqueue knote, epoll
   interest list, IOCP completion port in readiness mode).
2. Discharge `register` by issuing the kernel registration and
   returning a fresh token bound to that registration.
3. Discharge `wait` by blocking the *current task* (not the OS
   thread) until the kernel reports readiness.
4. Discharge `modify` by updating the kernel-side mask atomically.
5. Discharge `unregister` by removing the kernel-side registration
   and freeing any internal accounting for the token.
6. Discharge §4.1 — §4.4 of E_Event. §4.5 is enforced statically by
   the Swift type system (~Copyable Token).
7. Be **concurrency-safe**: multiple tasks may concurrently
   register/wait/unregister *different* tokens.

Cancellation: a `wait` on a cancelled task must throw
`CancellationError` and leave the token in `Registered` state
(unchanged). The token may then be reused or unregistered.

## 6. Current implementation

| Element | Source |
|---------|--------|
| Handler witness | `IO.Event.Driver` (capability struct) |
| Selector | `IO.Event.Selector` (kernel-handle wrapper) |
| Selector lifecycle | `IO.Event.Selector.Scope` |
| Channel (registered fd) | `IO.Event.Channel` |
| Reader/Writer halves | `IO.Event.Channel.{Reader,Writer}` |
| Token | `IO.Event.Token<Phase>` |
| Error type | `IO.Event.Error` |
| Platform handlers | kqueue (Darwin), epoll (Linux) |

See `io-event-channel-hardening.md` for handler-level safety
properties (deinit safety, fd leak prevention) that operationalise
the obligations above.

## 7. Open work

1. **Edge-triggered vs level-triggered semantics**: epoll supports
   both modes. Settle whether Σ_Event commits to one (level) or
   exposes both (handler-determined). Currently committed to
   level-triggered for portability with kqueue.
2. **EVFILT_USER / eventfd lifting**: cross-thread wakeup primitive
   sits below Σ_Event but is currently embedded in the handler.
   May warrant promotion to `Σ_Event.signal` operation.
3. **Multishot poll**: io_uring's `IORING_OP_POLL_ADD` with
   multishot is a hybrid Event-via-Completion bridge. It is
   currently handled inside `IO.Completion.Driver`; consider whether
   it should appear as a Σ_Event operation when running on
   io_uring.
4. **Tier-2 priority channels**: today the channel layer fans out
   readiness events to per-priority sub-channels. This is a
   handler-level extension, not a signature concern.
