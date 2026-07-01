# Σ_Blocking — Effect Signature

> **CORRECTIVE BANNER (2026-04-20)**: This note overshot. It elaborates
> handler-internal operations into prose that reads like a public algebra
> spec. The **public Σ_IO is the four operations on `IO`**: `read`,
> `write`, `close`, `ready` (see `Sources/IO Core/IO.swift:133` and
> `Research/README.md`). The `dispatch` operation described below is
> *internal* to the `IO.Blocking.Actor` implementation; consumers see it
> only as `IO.run.blocking { … }` sugar. Do not cite this note's
> contents as the public IO surface.

<!--
---
version: 1.0.0
created: 2026-04-20
status: DRAFT
purpose: |
  Per-component signature note for the Blocking sub-theory of Σ_IO.
  Enumerates operations, types, and equational obligations on
  handlers.

basis: io-algebraic-effects-foundation.md §6.1, swift-io-thesis.md §3.1
---
-->

## 1. Position

Σ_Blocking is the smallest sub-signature of Σ_IO. It captures the
single algebraic effect of *dispatching synchronous work to a
context that may safely block*, without blocking the calling task.

In the algebraic effects framework: dispatch is a single operation
with a function-typed argument and a polymorphic resume type.

## 2. Operations

```
dispatch[A] : (Work → A) → A
```

Read: dispatch takes a thunk producing `A`, executes it on a
blocking-safe substrate, and resumes the caller with the value.

The continuation receives exactly the value the thunk returned. If
the thunk throws, the continuation receives the thrown error
(typed throws as `dispatch[A][E] : (() throws(E) → A) → A`).

That is the entire signature. There are no other operations.

## 3. Types

| Symbol | Concrete Swift |
|--------|----------------|
| `Work → A` | `() throws(E) -> A` (sync closure) |
| `A` | resume value (any type) |
| `E` | resume error (typed throws) |

## 4. Equational laws (E_Blocking)

### 4.1 Transparency
```
dispatch(λ_. return v)   ≡   return v
```
A dispatched pure return is observationally equal to a direct return.
Handler is free to optimise the no-op case (skip thread hop).

### 4.2 Sequential composition
```
dispatch(λ_. work_a) >>= λa.
  dispatch(λ_. work_b a)
  ≡
dispatch(λ_. let a = work_a in work_b a)
```
Two consecutive dispatches with no intervening async work are
observationally equal to a single dispatch of the composed work.
Handler may fuse if the work is referentially transparent.

> **Note**: 4.2 is *extensionally* true (same returned value) but
> *operationally* may differ — a handler that keeps each dispatch
> on a separate thread observation may differ from a handler that
> fuses. Mark as conditional on handler class.

### 4.3 Error transparency
```
dispatch(λ_. throw e)   ≡   throw e
```
A dispatched throw resumes the caller with the same error, in the
caller's isolation. The thrown error is *not* coerced to a wrapper.

## 5. Handler obligations

A handler `H_Blocking` for Σ_Blocking must:

1. Execute `Work → A` on a substrate where the work may block
   (sleep, perform synchronous syscalls, do CPU-bound computation)
   *without* blocking the calling task's executor.
2. Resume the caller in the caller's isolation, with the work's
   return value or thrown error.
3. Discharge §4.1 (no-op transparency) at minimum. §4.2 (fusion)
   is optional. §4.3 (error transparency) is required.

Cancellation is handler-defined but recommended:
- If the calling task is cancelled before dispatch begins, throw
  `CancellationError` without running the work.
- Once the work has started, cancellation behaviour is
  handler-specific (work may complete or may be interrupted).

## 6. Current implementation

| Element | Source |
|---------|--------|
| Handler | `IO.Blocking` (thread pool) |
| Sync entry | `IO.run.blocking { ... }` (returns `Handle<T>`) |
| Async entry | `try await IO.run.blocking { ... }` (returns `T`) |
| Configuration | `IO.Blocking.Options` (pool size, queue depth) |
| Error type | `IO.Blocking.Error` |

See `perfect-api.md` §"IO.run.blocking" for the consumer-facing
surface; `io-architecture.md` §"IO Blocking" target for placement.

## 7. Open work

1. **Cancellation semantics**: settle the contract for in-flight
   cancellation. Today the implementation runs the work to
   completion; future versions may support cooperative
   interruption via thread signals or futex.
2. **Priority hints**: the thread-pool handler does not currently
   honour priority hints from the caller's task. Adding this is a
   handler refinement, not a signature change.
3. **Multi-pool dispatch**: extension to `dispatch_on : (Pool, Work
   → A) → A` for callers who want to target a specific pool. This
   is a signature extension, not an equation refinement.
