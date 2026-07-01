---
title: Proactor Generalization to IOCP — Primitives-Only Executor Shell or Reactor Adaptation
version: 0.1.0
status: DEFERRED
statusDetail: "DEFERRED 2026-05-31 per [META-002]/[META-022]. Analysis is a stub. Blocker: no Windows consumer + no IOCP primitives. Resumption trigger: a Windows consumer materializes AND swift-windows-standard provides IOCP (GetQueuedCompletionStatusEx) primitives; then answer the four sub-questions in Context."
tier: 3
created: 2026-04-16
last_updated: 2026-05-31
applies_to:
  - swift-foundations
  - swift-io
  - swift-executors
  - swift-kernel
  - swift-windows-standard
---

# Context

The Completion.Loop unification session killed Option A (adapt io_uring
through `Kernel.Thread.Executor.Polling`) because the proactor's
flush-before-wait constraint doesn't fit Polling's `drain → wait → tick`
run loop. The flush-before-wait deadlock generalizes: the proactor's
defining property is that submissions must reach the kernel before the
blocking wait, and the reactor's defining property is that the wait is
the first blocking call. Option B (primitives-only refactor, keeping
the 5-phase proactor loop in swift-io) was the right answer for
io_uring. Windows IOCP is the next proactor backend the ecosystem will
need — when a Windows consumer exists, the same question reopens: adapt
IOCP through Polling's reactor shell (wrong, per Phase 3b analysis), or
give IOCP its own primitives-only executor shell like `IO.Completion.Loop`?

# Question

Does the proactor pattern generalize to IOCP (Windows)? Specifically:

- Does IOCP have the same flush-before-wait constraint as io_uring, or
  does `GetQueuedCompletionStatusEx` have different ordering semantics?
- Does IOCP need its own primitives-only executor shell (like
  `Completion.Loop`), or can it share the existing shell with a backend
  swap?
- How does IOCP's thread-pool-of-completion-port-handlers model map to
  Swift's `TaskExecutor` / `SerialExecutor` shapes? (IOCP is inherently
  multi-threaded; io_uring is single-threaded + notification eventfd.)
- What's the abstraction seam — `Kernel.Completion.Queue` (primitives)
  or `IO.Completion.Loop` (foundations)?

# Prior Work

- `swift-foundations/swift-io/Research/completion-loop-executor-unification.md`
- `swift-foundations/swift-io/Research/io-uring-integration-architecture.md`
- `swift-foundations/swift-io/Research/io-completions-file-classification.md`
- `swift-foundations/swift-io/Research/io-proactor-buffer-ownership.md`
- Source reflection: `swift-io/Research/Reflections/2026-04-15-completion-loop-proactor-reactor-boundary.md`

# Analysis

_Stub — to be filled in during investigation._

Key sub-questions to work through:

- What does tokio's Windows backend do? What does libuv's IOCP backend
  do? Does either expose an executor-shaped abstraction consumers use?
- Can the `Kernel.Completion` L1 types (Notification, Queue) be made
  backend-agnostic enough that IOCP slots in, or do they bake in
  io_uring's submission-ring assumption?
- What does the IOCP run loop look like? (GetQueuedCompletionStatusEx
  in a loop, per-handle concurrency?) Can that share the 5-phase
  structure?

# Outcome

_Placeholder — to be filled when analysis completes._

# Provenance

Source: `swift-foundations/swift-io/Research/Reflections/2026-04-15-completion-loop-proactor-reactor-boundary.md` action item.
