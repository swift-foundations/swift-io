# Proactor Buffer Ownership — Q2 Resolution

<!--
---
version: 1.0.0
created: 2026-04-14
status: RESOLVED — Q2 passes; unified `_read` witness signature retained
tier: 2
related:
  - swift-io/Research/io-phase-2-plan.md §2 Q2
  - swift-io/Research/io-architecture.md v1.2 "Buffer ownership"
  - swift-io/Experiments/proactor-buffer-ownership/RESULTS.md
---
-->

## Question

Does the unified `_read(borrowing Kernel.Descriptor, Memory.Buffer.Mutable)
async throws(IO.Error) -> Int` witness signature survive io_uring
completions, where the kernel holds the buffer pointer from SQE
submission through CQE consumption?

This is Q2 of the Phase 2B plan (`io-phase-2-plan.md` §2). It gates
Phase 2C — passes mean the Completions factory uses the same witness
signature as Blocking and Events; fails mean proactor splits off into
`_readRegistered` with kernel-managed buffers.

## Resolution — Option (a), document-and-accept

**The unified signature is safe.** The buffer-ownership contract is:

> `Memory.Buffer.Mutable` / `Memory.Buffer` parameters to the `_read`,
> `_write`, and `_ready` closures MUST refer to storage whose address
> is stable for the duration of the enclosing `try await` expression.
> "Stable address" is the necessary and sufficient condition — it
> does not mandate heap-backed storage specifically. Any storage with
> a stable address over the await qualifies: explicit heap allocation
> (`UnsafeMutableRawBufferPointer.allocate`, `Buffer.Aligned`), Array
> storage (heap-backed under the hood), or local values in an async
> function whose address is captured inside a non-escaping
> `withUnsafe…` closure whose body contains the await (the async
> task's frame is heap-allocated, so "stack" locals in async
> functions are effectively heap-addressed across suspension).
>
> Stack-based `MutableSpan` views that would attempt to cross `await`
> boundaries are compile-time prevented by `~Escapable` lifetime
> rules — the unsafe pattern the architecture doc v1.2 flagged is
> blocked by the type system, not by this contract.
>
> Under the completions strategy, the factory MUST wrap in-flight SQE
> awaits with `withTaskCancellationHandler` so that a cancelled task
> submits `IORING_OP_ASYNC_CANCEL` and waits for the original SQE's
> cancel CQE before the owning frame unwinds. This is an
> implementation requirement on `IO.Completions.Actor`, not a
> signature change.

## Evidence

Empirical verification at
`swift-io/Experiments/proactor-buffer-ownership/`. Two Linux Docker
runs with `swiftlang/swift:nightly-main` + `liburing-dev`:

- **testA** — heap-backed `UnsafeMutableRawBufferPointer.allocate(16)`
  submitted as the buffer to `IORING_OP_READ` on a pipe, suspended on
  a `CheckedContinuation` while a separate task wrote to the pipe's
  write end. Kernel wrote the bytes into the buffer; continuation
  resumed with the correct `res` value; buffer contents matched.
  **PASS.**
- **testB** — SQE submitted on a pipe with no writer. After 10 ms,
  `IORING_OP_ASYNC_CANCEL` submitted with the original SQE's
  `user_data`. Cancel completed promptly; original SQE's CQE returned
  `res = -ECANCELED` (=`-125` on Linux); buffer remained all-`0xAA`
  (sentinel never overwritten). **PASS.**

Full output, setup, and reproduction steps:
`swift-io/Experiments/proactor-buffer-ownership/RESULTS.md`.

## Implications for Phase 2C

1. **Keep `_read` / `_write` / `_close` / `_ready` signatures unchanged.**
   No `_readRegistered` variant. No per-strategy signature divergence.
   No `platformBest` reconciliation burden (2D stays simple per plan §4.D).

2. **`IO.Completions.Actor` must implement `withTaskCancellationHandler`
   around each SQE await.** The on-cancel closure submits
   `IORING_OP_ASYNC_CANCEL` for the request's `user_data`. The original
   SQE's CQE (with `-ECANCELED`) is awaited before the continuation
   resumes — so the buffer outlives the in-flight kernel access.

3. **Buffer-ownership doc goes in `IO.swift`.** The contract above is
   added to the `IO` struct's doc comment as part of 2D's polish
   phase (per plan §4.D step 2). Consumers reading the witness API
   see the contract inline.

4. **Regression test in Completions target.** A test that mirrors
   this experiment's testB — submit a read, cancel the task, verify
   no UAF — lands with the first `IO.completions(_:)` factory
   implementation in Phase 2C.

## Why option (a) over (b) or (c)

Plan §2 Q2 listed three options:

| Option | Approach | Chosen? |
|---|---|---|
| (a) Document invariant, accept the trap | Heap-backed caller storage + factory handles cancel correctness | ✅ |
| (b) Split proactor into `_readRegistered` | Kernel-managed buffers exposed as a parallel witness op | ❌ |
| (c) Buffer-pool abstraction at swift-io layer | New public type for pool-managed buffers | ❌ |

Option (b) would require every caller of the completions witness to
adopt a different API, defeating the domain-agnostic layering. It
also propagates the buffer-pool concern into every consumer package
(swift-sockets, swift-file-system, swift-pipes). The experiment
shows the trap is both narrow (stack-based ~Escapable views, already
compile-prevented) and absorbable by factory implementation
(cancellation handling), so (b) solves a problem that doesn't
materialize.

Option (c) would add a public type for kernel-registered buffers — a
premature optimization ahead of any consumer explicitly asking for
the zero-copy IORING_OP_READ_FIXED path. Phase 2C ships the unified
surface; if a benchmark later shows that fixed-buffer registration
is load-bearing for specific workloads, a `readRegistered` variant
can be added at that point as a non-breaking addition to `IO.Events`
/ `IO.Completions` configs (not a witness-signature change).

Option (a) is correct for v1 and leaves (c) open as a future
optimization if benchmarks justify it.

## Status

**Q2 resolved (pass).** Phase 2C proceeds with unified `_read`
signature. Next commit: IO.Completions.Actor skeleton + factory on
top of the retained io_uring primitives in `IO Completions` target.
