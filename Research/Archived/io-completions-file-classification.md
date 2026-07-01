# IO Completions File Classification — Phase 2C Option B

<!--
---
version: 1.0.0
created: 2026-04-14
status: COMMITTED — classification for Phase 2C reset
tier: 2
related:
  - swift-io/HANDOFF.md (Phase 2C operating plan)
  - swift-io/Research/io-architecture.md v1.2
  - swift-io/Research/io-phase-2-plan.md §4.C
  - swift-io/Research/io-proactor-buffer-ownership.md (Q2 resolution)
---
-->

## Purpose

Inventory of the 52 files under `Sources/IO Completions/` plus `exports.swift`,
classified into four buckets per the HANDOFF's "Next Steps #1". Drives the 2C
reset: delete the public-handle + socket-consumer layers, extract the
poll-thread machinery into `IO.Completion.Loop`, and build
`IO.Completions.Actor` + `IO.completions(_:)` factory on top of the retained
kernel-interface primitives.

Author-review bucket labels from `HANDOFF-io-phase-1-author-review.md §3`
(Bucket A = migrate / delete; Bucket B = fd-generic retain; Bucket C = audit)
are cross-referenced where relevant.

## A. Kernel-interface — KEEP (21 files)

Domain-agnostic proactor primitives. The `@Witness` `Driver` and its opcode /
event / flag / error vocabulary. Survive the reset unchanged.

| File | Role |
|---|---|
| `IO.Completion.Driver.swift` | `@Witness` over IOCP / io_uring / Darwin-unsupported |
| `IO.Completion.Driver+Platform.swift` | Platform factories (`bestAvailable`) |
| `IO.Completion.Driver.Capabilities.swift` | Driver feature flags |
| `IO.Completion.Driver.Handle.swift` | Driver handle wrapper |
| `IO.Completion.Operation.swift` | Opcode enum incl. `.accept` / `.connect` — complete enum retained per author review §3.B |
| `IO.Completion.Operation.Storage.swift` | Internal op storage |
| `IO.Completion.Entry.swift` | CQE-shaped entry |
| `IO.Completion.Event.swift` | Completion event |
| `IO.Completion.Flags.swift` | Op flags |
| `IO.Completion.ID.swift` | Op ID (decoupled from `Queue.ID`) |
| `IO.Completion.Kind.swift` | Op kind tag |
| `IO.Completion.Kind.Set.swift` | Op kind set |
| `IO.Completion.Outcome.swift` | Op outcome |
| `IO.Completion.Success.swift` | Success payload |
| `IO.Completion.Cancellation.swift` | Cancellation enum |
| `IO.Completion.Cancellation.Flag.swift` | Atomic cancellation flag |
| `IO.Completion.Error.swift` | Error umbrella |
| `IO.Completion.Error.Capability.swift` | Capability errors |
| `IO.Completion.Error.Lifecycle.swift` | Lifecycle errors — `.queueClosed` RENAMES to `.loopClosed` |
| `IO.Completion.Error.Operation.swift` | Operation errors |
| `IO.Completion.Error.Operation.Queue.swift` | RENAME → `IO.Completion.Error.Operation.Loop.swift` (Queue term becomes stale) |

Rename carried from the 2B "moved-nesting" pattern: `Queue` → `Loop`
identifiers inside Lifecycle / Operation error families.

## B. Fd-generic result types — KEEP (6 files)

Read / Write result envelopes. Author-review Bucket B (fd-generic). The
witness `_read` / `_write` return `Int`, but these envelopes remain as
internal plumbing inside the Actor for bridging CQE outcomes to witness
return shape.

| File | Role |
|---|---|
| `IO.Completion.Read.swift` | Namespace for read result family |
| `IO.Completion.Read.Result.swift` | Read result (`Buffer.Aligned + count`) |
| `IO.Completion.Read.Result.Bytes.swift` | Read bytes accessor |
| `IO.Completion.Write.swift` | Namespace for write result family |
| `IO.Completion.Write.Result.swift` | Write result (`Buffer.Aligned + count`) |
| `IO.Completion.Write.Result.Bytes.swift` | Write bytes accessor |

## C. Extract into IO.Completion.Loop — MOVE (12 files)

Submission + poll thread + wakeup + shutdown machinery currently owned by
`IO.Completion.Queue`. Extracted into a new class
`IO.Completion.Loop : SerialExecutor, TaskExecutor, @unchecked Sendable`
mirroring `IO.Event.Loop`. The files themselves stay; ownership moves from
the deleted `Queue` to the new `Loop`.

| File | Role in Loop |
|---|---|
| `IO.Completion.Poll.swift` | `Loop.runLoop()` body |
| `IO.Completion.Poll.Context.swift` | Poll-thread context (becomes `Loop`-internal) |
| `IO.Completion.Poll.Exit.swift` | Poll-thread exit notification |
| `IO.Completion.Poll.Shutdown.swift` | Shutdown signal |
| `IO.Completion.Poll.Shutdown.Flag.swift` | Atomic shutdown flag |
| `IO.Completion.Submit.swift` | Submit namespace |
| `IO.Completion.Submit.Result.swift` | Internal submit result (Actor-internal after reset) |
| `IO.Completion.Submit.Take.swift` | Internal take handle (Actor-internal after reset) |
| `IO.Completion.Submission.swift` | MPSC submission record |
| `IO.Completion.Submission.Queue.swift` | MPSC submission queue |
| `IO.Completion.Wakeup.swift` | Wakeup namespace |
| `IO.Completion.Wakeup.Channel.swift` | Eventfd / IOCP wakeup wrapper |

Access-level audit per [API-IMPL-010]: members widened from `package` to
`internal` as they become Loop-internal machinery rather than cross-boundary
plumbing. Types previously `public` for the Queue public API (Submit.Result,
Submit.Take) downgrade to `internal`.

## D. Public-handle-interface — DELETE (7 files)

`IO.Completion.Queue` and its satellites. Replaced by `IO.Completion.Loop`
(internal) + `IO.Completions.Actor` (internal) + `IO.Completions` config +
`IO.completions(_:)` factory. No public handle type survives.

| File | Reason |
|---|---|
| `IO.Completion.Queue.swift` | Public class → replaced by internal Loop |
| `IO.Completion.Queue.ID.swift` | Queue-scoped ID counter → folded into Loop |
| `IO.Completion.Queue.Make.swift` | Make factory namespace → unused |
| `IO.Completion.Queue.Make.Result.swift` | Queue + shutdown token bundle → unused |
| `IO.Completion.Queue.Scope.swift` | Queue scope → unused |
| `IO.Completion.Queue.Shutdown.swift` | Queue shutdown namespace → unused |
| `IO.Completion.Queue.Shutdown.Token.swift` | Shutdown token → unused |

## E. Socket-consumer-interface — DELETE (5 files)

Socket-specific thin wrappers. Not part of domain-agnostic swift-io per
architecture v1.2. NOT migrated to swift-sockets — swift-sockets composes via
witness `_ready` + iso-9945 accept/connect (same pattern as 2B).

| File | Reason |
|---|---|
| `IO.Completion.Channel.swift` | Socket-specific public handle |
| `IO.Completion.Accept.swift` | Socket accept wrapper |
| `IO.Completion.Accept.Result.swift` | Accept result envelope (Gap 4 — would need `Kernel.Socket.Descriptor` if retained; moot) |
| `IO.Completion.Connect.swift` | Socket connect wrapper |
| `IO.Completion.Connect.Result.swift` | Connect result envelope |

## F. Top-level namespace + exports — KEEP / UPDATE (2 files)

| File | Action |
|---|---|
| `IO.Completion.swift` | Keep; update docstring — remove "Pending Phase 2 Refactor" section (no longer pending) |
| `exports.swift` | Keep as-is |

## G. New files to add

| File | Role |
|---|---|
| `IO.Completion.Loop.swift` | Internal executor (mirrors `IO.Event.Loop`) |
| `IO.Completions.Actor.swift` | Internal actor (mirrors `IO.Events.Actor`) |
| `IO.Completions.swift` | Per-strategy config struct (mirrors `IO.Events`) |
| `IO+Completions.swift` | `IO.completions(_:)` factory (mirrors `IO+Events.swift`), Linux-guarded |

Plus smoke tests under `Tests/IO Completions Tests/`:

| File | Purpose |
|---|---|
| `IO.Completions.PipeRoundTrip.Tests.swift` | Pipe read/write via completions |
| `IO.Completions.Ready.Tests.swift` | Single-shot `_ready` regression per constraint #4 |
| `IO.Completions.Cancellation.Tests.swift` | Cancel handshake regression per constraint #2 (mirrors Q2 experiment testB) |

The existing `IO.Completion.Queue Tests.swift` + `IO.Completion.Driver.Fake.swift`
are deleted with the Queue public surface.

## Summary

| Bucket | Count | Action |
|---|---|---|
| A. Kernel-interface | 21 | Keep (2 renames) |
| B. Fd-generic results | 6 | Keep |
| C. Extract into Loop | 12 | Move (ownership shift) |
| D. Public-handle-interface | 7 | Delete |
| E. Socket-consumer-interface | 5 | Delete |
| F. Namespace + exports | 2 | Keep (1 docstring update) |
| **Total existing** | **53** | — |
| G. New files | 4 | Add |

Net file count change: 53 existing − 12 deleted (D + E) + 4 new (G) = **45 files** after reset.

Plus tests: 2 existing deleted, 3 new added.

## Supervisor constraint mapping

- **#1 Buffer-ownership wording**: applied in `IO.swift` docstring in Phase 2D;
  for 2C the contract lives on `IO.Completions.Actor.read/write` doc comments.
  "Stable address for duration of try await" — NOT "heap-backed".
- **#2 Cancel handshake**: implemented in `IO.Completions.Actor` via
  `withTaskCancellationHandler` + `IORING_OP_ASYNC_CANCEL` submission +
  awaiting both original CQE and cancel CQE. Regression test in
  `IO.Completions.Cancellation.Tests.swift`.
- **#3 Linux-only guard**: `IO+Completions.swift` uses `#if os(Linux)` around
  the factory; Darwin callers get a compile error. Docstring the factory.
- **#4 POLL_ADD single-shot**: `_ready` under completions submits
  `IORING_OP_POLL_ADD` WITHOUT `IORING_POLL_ADD_MULTI`. Regression test in
  `IO.Completions.Ready.Tests.swift` verifies re-register on each call.
