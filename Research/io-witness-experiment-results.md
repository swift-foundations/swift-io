# IO Witness Experiment Results

<!--
---
version: 1.0.0
last_updated: 2026-04-13
status: RECOMMENDATION
tier: 2
---
-->

## Finding

`IO` itself can be a `@Witness` struct that serves as both the witness (swappable
closures) AND the namespace (nested types via extensions). Validated experimentally.

## Experiment

Package at `/tmp/io_witness_test/`. Key results:

1. `@Witness` on `IO` struct — compiles, generates `Calls` enum, `observe()`,
   `unimplemented()`, labeled init
2. Nested types via extensions (`IO.Event`, `IO.Event.Channel`,
   `IO.Completion.Submission`) — work identically to enum namespace
3. `IO.bestAvailable()` / `IO.fake()` / `IO.unimplemented()` — all work
4. Parameter-less closures (`_flush`, `_close`) — `@Witness` doesn't generate
   wrapper methods (no labels to derive name from). Needs macro improvement.

## Architecture Decision

`IO` as witness means the entire I/O strategy is injectable:

```
IO.bestAvailable()  — kernel event loop + io_uring/kqueue (Kernel.Completion + Kernel.Event)
IO.blocking()       — thread pool + blocking syscalls
IO.fake()           — test double
IO.unimplemented()  — stub from @Witness
```

The IO witness closures compose both readiness (reactor) and completion (proactor):

| Closure | bestAvailable() | blocking() |
|---------|----------------|------------|
| _register | epoll/kqueue | no-op |
| _submit | io_uring SQE | thread pool enqueue |
| _flush | io_uring_enter | no-op |
| _poll | epoll_wait + CQ drain | wait for pool completions |
| _close | close ring + epoll | shut down pool |

## Prior Research Reconciliation

`architecture-refactor.md` says "No premature universal witness" at the kernel level.
This is correct — Kernel.Event.Driver and Kernel.Completion.Driver stay separate at L3.

But `IO` at L4 IS the universal witness — it's the consumer-facing abstraction.
It composes kernel resources internally; the consumer sees one interface.
This is not premature unification — it's the right abstraction level.

## Macro Improvement Needed

`@Witness` doesn't generate wrapper methods for parameter-less closures.
Packages to investigate:
- `swift-witness-primitives`: `/Users/coen/Developer/swift-primitives/swift-witness-primitives`
- `swift-witnesses`: `/Users/coen/Developer/swift-foundations/swift-witnesses`
- `swift-dual`: `/Users/coen/Developer/swift-foundations/swift-dual` (may help)

## References

- `swift-foundations/Research/io-driver-witness-composition.md` — full analysis
- `swift-io/Research/architecture-refactor.md` — prior art (recommends against kernel-level unification)
- `swift-institute/Research/witness-macro-io-drivers-assessment.md` — @Witness for IO drivers
