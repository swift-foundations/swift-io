---
date: 2026-04-08
session_objective: Fix P0 blocking sync path regression, simplify swift-io architecture, consolidate API design
packages:
  - swift-io
  - swift-async-primitives
  - swift-algebra-primitives
status: processed
processed_date: 2026-04-16
triage_outcomes:
  - type: skill_update
    target: implementation
    description: "Added [IMPL-084] Single-Inhabitant Namespaces"
  - type: skill_update
    target: implementation
    description: "Added [IMPL-085] Prefer sending + nonisolated(unsafe) over @unchecked Sendable"
  - type: no_action
    description: "[package] IO.run(descriptor) implementation — execution task tracked in handoffs/perfect-api.md"
---

# Architectural Simplification and API Consolidation

## What Happened

Session started with a focused P0 fix (sync submission path touching cooperative pool) and expanded into a full architectural overhaul. Seven commits, net -13,500 LOC:

1. **P0 fix**: Replaced `Task { try await driver.run(op) }` with `Handle.Slot` — a one-shot rendezvous using `Kernel.Thread.Synchronization`, `UnsafeContinuation`, and `nonisolated(unsafe)` for cross-region transfer. No cooperative pool involvement, no `T: Sendable`.

2. **7→5 targets**: Deleted IO Executor (35 files of premature handle registry, slot pools, lifecycle builders), absorbed IO Stream into IO umbrella. The theoretical-perfect-io-api.md defined 24 types — none of them were in IO Executor.

3. **Namespace collapse**: IO.Blocking.Driver → IO.Blocking (empty namespace had one inhabitant).

4. **Type extraction**: IO.Failure.Work → Either (from algebra-primitives), IO.Lifecycle.Error → Async.Lifecycle.Error (moved to async-primitives). Both were general-purpose types wearing IO namespaces.

5. **Research consolidation**: 11 superseded documents (7,392 lines) → 1 consolidated `perfect-api.md` (383 lines).

6. **API design**: Converged on `IO.run` as the universal entry point — three overloads (multi-stream runtime, single-stream with reader+writer closure, blocking work). Progressive disclosure via import: `import IO` = Tier 0, `import IO_Events` = Tier 1+.

## What Worked and What Didn't

**Worked well**: The "pedantic university professor" framing produced genuinely rigorous analysis. The question "does this type exist because of I/O, or is it general-purpose wearing an IO namespace?" was the right scalpel — it identified IO.Backpressure, IO.Closable, IO.Failure.Scope, IO.Failure.Work, IO.Lifecycle, and IO.Lifecycle.Error as extraction candidates. All were confirmed dead or relocatable.

**Worked well**: Deleting before adding. The session deleted ~13,500 lines and added ~700. The codebase is simpler after every commit. The user's instinct to question every abstraction ("why use 'open' at that point?", "why not just one closure with both parameters?") consistently found simpler designs.

**Didn't work**: The initial Handle.Slot implementation used `@unchecked Sendable` — the user pushed back and the design improved to use no Sendable at all (Handle is ~Copyable, consumed in same context; Slot uses `nonisolated(unsafe)` for transfers). The first instinct was the conventional answer; the better answer required questioning whether Handle needed to be Sendable at all.

**Didn't work**: Over-analysis before implementation. The P0 fix took significant exploration time (executor API surface, synchronization primitives, Sendable constraints) before the design was clear. A faster path would have been: implement the simplest correct thing, then refine. The user's "what's taking so long" was warranted.

## Patterns and Root Causes

**Pattern: empty namespaces signal premature abstraction.** IO.Blocking was an empty enum routing to IO.Blocking.Driver. IO.Failure was an empty enum routing to IO.Failure.Work. Both had exactly one inhabitant. The pattern: if a namespace enum has one type, the type IS the namespace. Collapsing them always simplified.

**Pattern: general-purpose types accumulate in the package that first needed them.** IO.Lifecycle.Error (shutdown/cancellation/timeout/failure) is a concurrency concept, not an I/O concept. IO.Failure.Work (Either with labels) is an algebraic concept. Both lived in IO Core because that's where they were first used. The extraction test: "would a non-IO package need this?" If yes, it doesn't belong in IO.

**Pattern: the simplest API is always one level shallower than you think.** The progression was: `IO.Blocking.Driver.shared.run.sync { }` → `IO.run.blocking { }` → same call site for sync AND async (compiler disambiguates by `await`). Then: `IO.Stream(socket, in: io)` → `IO.open(socket) { stream in }` → `IO.run(socket) { reader, writer in }`. Each step removed a concept the consumer had to learn.

**Root cause of IO Executor's 35 files**: it was built top-down from a theoretical design, not bottom-up from consumer need. Handle.Registry, Slot pools, Pending→Ready builders — none had external consumers. The theoretical-perfect-io-api.md didn't call for any of them. They were infrastructure looking for a use case.

## Action Items

- [ ] **[skill]** implementation: Add guidance — "if a namespace enum has exactly one type, the type IS the namespace" as a corollary of [PATTERN-013] (no premature abstractions)
- [ ] **[package]** swift-io: Implement `IO.run(descriptor) { reader, writer in }` — the single-stream entry point from `Research/perfect-api.md`
- [ ] **[skill]** implementation: Add guidance — prefer `sending` + `nonisolated(unsafe)` over `@unchecked Sendable` for cross-region value transfer where a lock provides synchronization (codify the Handle.Slot pattern)
