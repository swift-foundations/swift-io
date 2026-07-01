# swift-io Research — Entry Point

**Read this first.** This document is the canonical entry point for any
agent (human or AI) working in `swift-io/Research/`. The notes around
this README are *background and history*; this README is the source of
truth about what swift-io currently is.

---

## What swift-io is

swift-io is the IO substrate for the Swift Institute ecosystem. It
provides a single, strategy-agnostic witness type that consumers
(`swift-file-system`, `swift-server`, …) compose against. Three
handler families discharge that witness against platform IO
mechanisms.

## The public algebra

The witness is `IO`, defined at `Sources/IO Core/IO.swift:133`. It is a
`@Witness`-macro-generated `Sendable` struct with five fields — four IO
operations plus one scheduling-topology field:

| Field | Signature | Algebraic role |
|-------|-----------|----------------|
| `read` | `(borrowing FD, Memory.Buffer.Mutable) async throws(IO.Error) -> Int` | operation |
| `write` | `(borrowing FD, Memory.Buffer) async throws(IO.Error) -> Int` | operation |
| `close` | `(consuming FD) async -> Void` | operation |
| `ready` | `(borrowing FD, Kernel.Event.Interest) async throws(IO.Error) -> Void` | operation (readiness composition) |
| `unownedExecutor` | `() -> UnownedSerialExecutor` | scheduling metadata, not an IO op |

These four operations are the **public Σ_IO**. Anything richer is
either an extension (consumer-built, by signature coproduct) or
internal to a handler implementation. Do not present internal handler
operations as if they were part of the public algebra.

## The three handler families

| Strategy | Factory | Implementation | Platform |
|----------|---------|----------------|----------|
| Blocking | `IO.blocking(_:)` | `IO.Blocking.Actor` | All |
| Events (reactor) | `IO.events(on:)` | `IO.Event.Actor` | Darwin (kqueue), Linux (epoll) |
| Completions (proactor) | `IO.completions(on:)` | `IO.Completion.Actor` | Linux (io_uring) |

A consumer chooses a strategy at construction and receives an `IO`
value. After construction, the strategy is invisible. `IO.default()`
provides a host-adaptive factory that picks the best available
strategy with fallback to blocking (`Sources/IO/IO+Default.swift:19`).

## What swift-io is **not**

These belong elsewhere. Consumers needing them should import the
right package, not ask swift-io to grow.

| Concern | Lives in | API |
|---------|----------|-----|
| Arbitrary blocking-closure dispatch (admission-gated thread pool) | **swift-threads** | `Kernel.Thread.Pool.run { body }` from `Thread_Pool` |
| Path-based syscalls (open, stat, mkdir, unlink, rename, …) | consumer (e.g. swift-file-system) | dispatched via `Kernel.Thread.Pool.run` |
| Socket/HTTP/TLS protocols | swift-server / swift-sockets | own scoped APIs (e.g. `Socket.with(…)`) |
| Effect-system framework, free-monad encoding | not built; not planned | swift-io stands alone |

The 2026-04-14 strict-mission refactor extracted the
blocking-closure-dispatch primitive (`Kernel.Thread.Pool`) out of
swift-io into its own L3 package, swift-threads. swift-io's
`IO.Blocking` is now *only* a shard provider for the blocking
witness's impl actor. It does **not** host arbitrary `run { … }`
APIs. See `Research/Reflections/2026-04-14-strict-mission-thread-layer-refactor.md`.

## Source of truth (read these before any research note)

| File | What it tells you |
|------|-------------------|
| `Sources/IO Core/IO.swift` | The witness definition (`IO` struct, line 133) |
| `Sources/IO Events/README.md` | Reactor strategy — full conceptual model |
| `Sources/IO Completions/README.md` | Proactor strategy — full conceptual model |
| `Sources/IO/IO+Default.swift` | Host-adaptive factory and fallback chain |

The two source READMEs are 580 and 280 lines of careful documentation
of what is actually implemented. They supersede every research note in
this directory for questions about current behaviour.

---

## Anti-patterns — do not do these

These are mistakes that have been made in this corpus. Each one wasted
significant effort. Do not repeat them.

### 1. Do not cite types from `perfect-api.md`'s Tier 1+ table as if they exist

`perfect-api.md` documents both implemented and aspirational API. Its
Tier 1+ table at lines 188–211 lists *intended* types — most of which
do not exist in `Sources/`. The Implementation Status table at the
bottom of that doc (lines 364–381) is the authoritative status table.
Always grep `Sources/` to verify a type exists before naming it in
research.

Examples of types that *do not exist* despite appearing in
`perfect-api.md`:

Tier 1+ (never implemented):
- `IO.Event.Driver` (the actor `IO.Event.Actor` is the implementation)
- `IO.Event.{Channel, Selector, Token}` (none exist as types)
- `IO.Completion.Driver`, `IO.Completion.Queue`,
  `IO.Completion.{Read, Write, Accept, Connect}` (the actor
  `IO.Completion.Actor` plus `IO.Completion.Entry` is the
  implementation)

Tier 0 (deleted by the 2026-04-14 strict-mission refactor):
- `IO.run.blocking { body }` — extracted to `Kernel.Thread.Pool.run { body }` in **swift-threads**
- `IO.Blocking.Error` — replaced by `Kernel.Thread.Pool.Error` in swift-threads
- `IO.Run.Blocking`, `IO.Run` — deleted; no replacement in swift-io
- `IO.run(fd) { reader, writer in }`, `IO.run { io in }` — never landed; consumer code uses the witness directly

### 2. Do not propose adding an "effect system" dependency

swift-io is *already* an algebraic effect substrate. The witness
encodes the signature; the actors are law-preserving handlers; the
factories are dictionary constructors. No `swift-effect-primitives` or
similar framework needs to be imported. Algebra is a discipline for
*thinking* about this design, not a library to depend on.

### 3. Do not elaborate internal handler operations into "the public algebra"

Each handler internally uses richer operations (kqueue
register/wait/modify/unregister; io_uring submit/await; thread-pool
dispatch). These are *not* part of the public Σ_IO. The public algebra
is the four operations on `IO`. A research note describing internal
handler operations should explicitly say so and not be confused with
the consumer-facing surface.

The four `io-effect-signature-{blocking,event,completion,stream}.md`
notes, now in `Archived/`, made exactly this mistake. They are kept
for historical reference with a corrective banner.

### 4. Do not propose restoring per-strategy public witness types

There used to be intermediate per-strategy witness types
(e.g. `IO.Event.Driver` between the actor and the unified `IO`). They
were removed because they did not earn their keep — the actor IS the
runner, the unified `IO` IS the witness, and an intermediate witness
layer per strategy was redundant. The simplification is correct and
should not be reverted.

### 5. Do not add documentation that overcomplicates a working design

If the codebase already does something cleanly, research notes should
*describe and justify* it, not propose elaborate alternatives. The
`Σ_IO ⊕ Σ_Socket ⊕ Σ_File ⊕ …` coproduct framing is correct as a
description of how consumers extend, but it does not require any
restructuring of swift-io itself.

---

## Algebra and shape research lives upstream

The algebra grounding, the witness-shape exploration, and the literature
study **moved** to `swift-primitives/swift-io-primitives/Research/` on
2026-04-20. swift-io is the operational substrate (deliberately stable);
swift-io-primitives is the design playground (deliberately experimental).

For algebra / shape questions, read:
`/Users/coen/Developer/swift-primitives/swift-io-primitives/Research/README.md`

Specifically moved out:
- `io-algebraic-effects-foundation.md` — full algebra grounding
- `algebraic-effects-cheatsheet.md` — vocabulary reference
- `io-witness-design-literature-study.md` — design-space exploration
- `io-witness-shape-selection.md` — Shape F selection
- `io-witness-shape-zoo-addendum.md` — zoo analysis update
- `io-witness-capability-runner-split.md` — capability/runner rationale
- `io-witness-borrowing-async-tension.md` — witness/language tension

## Reading order for what stays here

If you want **strategic context for the substrate**:
1. `swift-io-thesis.md` — short position document
2. `Sources/IO Events/README.md`, `Sources/IO Completions/README.md`,
   `Sources/IO Blocking/README.md` — per-strategy implementation models

If you want **implementation history**:
- `io-architecture.md` — concrete five-target architecture (subordinated to thesis)
- `io-phase-2-plan.md` — Phase 2 execution contract
- `io-uring-integration-architecture.md` — io_uring binding
- `completion-queue-ownership-redesign.md` — single-point-authority law
- Operational notes: executor-binding, completion-ownership, event-channel-hardening, etc.

If you want **decision history**:
- `Reflections/` — chronological session reflections
- `Archived/README.md` — superseded / overshot notes

If you want **the corpus map**:
- `io-research-corpus-audit.md` — classification of all notes (now partially historical; see migration footnote at the bottom of that file)

## Conventions for adding new research notes

1. Frontmatter must declare `status: DRAFT|RECOMMENDATION|DECISION|HISTORICAL`.
2. State whether the note is aspirational or reflects current code.
3. Cite source files with `path:line` for every claim about implementation.
4. Cross-reference this README from any new top-level position note.
5. Before introducing new top-level concepts, grep `Sources/` to confirm
   they exist (or explicitly mark them aspirational).
6. If proposing structural change, name what concretely fails today
   that the change would fix. "Algebraically cleaner" is not enough.
