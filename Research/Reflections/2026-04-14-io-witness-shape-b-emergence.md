---
date: 2026-04-14
session_objective: Continue IO witness migration from handoff; land IO.blocking() with mandatory thread binding; prevent cooperative-pool deadlocks.
packages:
  - swift-io
  - swift-witnesses
  - swift-foundations
status: processed
processed_date: 2026-04-16
triage_outcomes:
  - type: no_action
    description: "[skill] implementation documentation — action item was vague (no specific rule proposed); pattern 'design collapses through engineering obstacles' is captured in [IMPL-086/087/090] additions from sibling reflections"
  - type: no_action
    description: "Skip research on Events/Completions shape — already converged via Framing E in io-events-completions-fate.md"
  - type: no_action
    description: "[package] Kernel.Thread.Executor.Sharded limitations — documentation task, not a reusable insight"
---

# IO Witness: Shape B Emergence via Iterative Design Collapse

## What Happened

Started from a handoff that prescribed IO as a `@Witness` struct exposing
kernel mechanisms (`_register`, `_submit`, `_poll`, `_drain`, `_flush`). Over
the session the design collapsed through four distinct shapes, each driven
by a concrete obstacle the previous shape couldn't clear:

1. **Shape 0 (handoff)**: `@Witness IO` with reactor/proactor closures fused.
   Rejected in conversation — "design from the consumer, not the mechanism."

2. **Shape 1 (my initial)**: `@Witness struct IO` with sync closures
   (`_read`, `_write`, `_accept`, `_close`) + `IO.run(_:body:)` using
   `Task(executorPreference:)`. Resolved the borrowing + async tension by
   making the closures sync. Tests passed. External review flagged this as
   advisory under load — SE-0417 documents the limitation, swift#74395
   confirms Task.sleep/yield don't honor preference.

3. **Shape F (investigation)**: actor-based `Runner` with three modes:
   `scope(...)` for non-Sendable captures, `Actor.run` fast path for
   Sendable captures, direct ad-hoc `await io.read(...)`. Sub-agent
   verified via four prototypes. Refined by user to a single mode: one
   public `actor IO`, direct methods only, shared-executor optimization
   (TCA26 precedent) handles hot-loop cost.

4. **Shape B (what other agents landed)**: `@Witness struct IO` holds
   `@Sendable async` closures that forward to an *internal* `IO.Blocking.Actor`
   pinned to `Kernel.Thread.Executor`. The struct is the public surface
   (preserving `IO.unimplemented()` / `IO.observe` / `IO.Calls` for free);
   the actor is the isolation boundary (mandatory binding via `unownedExecutor`).
   Tests pass. `IO.Events` and `IO.Completions` not yet refactored.

Key committed changes:
- swift-witnesses `f6350fc`: `@Witness` macro mirrors parent struct's `Sendable`
  conformance instead of hardcoding it. Unblocked witnesses with non-Sendable
  parameter types.
- swift-io `bbfa80f7` through `7e59b592`: full IO Core rewrite and IO Blocking
  rewrite on Shape B.

Research produced:
- `swift-io/Research/io-witness-borrowing-async-tension.md` (the tension)
- `swift-io/Research/io-witness-design-literature-study.md` (Tier 2 lit study —
  Runners calculus, Asynchronous Effects, Evidence Passing, Capabilities)
- `swift-io/Research/io-context-actor-analysis.md` (initial rejection of
  Context-as-actor — five of six rejections later dissolved by Shape F)
- `swift-io/Research/io-blocking-executor-binding.md` (v1 → v2 → v4 reversal
  on executor binding; v1 recommended advisory, v4 landed on actor)

## What Worked and What Didn't

**Worked**:
- **Collaborative critique pattern** (me ↔ user-as-ChatGPT-relay ↔
  sub-agents). Each cycle surfaced costs the previous design missed
  (pool-per-call, lossy error mapping, silent close, Task preference
  advisory, Sharded-as-SerialExecutor bug).
- **Literature grounding before implementation**. The Tier 2 study
  classified the problem as a Runner (Ahman & Bauer 2020) and gave
  vocabulary that made cross-agent discussion precise. Without it we
  would have thrashed between "actor vs closure vs effect" by taste.
- **Sub-agent investigation with empirical probes**. The actor-runner
  investigation produced four prototypes verifying concrete language
  constraints (`sending + isolated Self` bug, `borrowing ~Copyable`
  across async actor boundary, `nonisolated(nonsending)` scope
  semantics). Claims became verifiable.
- **Incremental commits with honest subjects**. Each architectural pivot
  is a recoverable state.

**Didn't work**:
- **My v1 recommendation was wrong** on executor binding. I read SE-0417
  carefully but still preferred Option A (advisory) because of engineering
  constraints (@Sendable, @Witness compat). User + other agents showed
  Option B (actor) dominates via a structural reshuffle I hadn't tried:
  keep `@Witness` on a struct, move the actor *inside*. v1 → v4 reversal.
- **Sequenced handoffs accumulated cross-repo plumbing errors**. I moved
  a research doc via `git mv` across a submodule boundary, corrupting the
  swift-foundations working tree (revert + recreate fixed it but wasted
  context). Submodules look like directories but aren't.
- **The `sending` replacement for `@Sendable` on actor-method body**
  reaches a Swift 6.3 compiler wall — region checker errors out with
  "please file a bug" for `sending + isolated Self` closure parameters.
  I confirmed via minimal reproduction; not fixable from our side.

## Patterns and Root Causes

### Pattern 1: Design collapses through engineering obstacles, not prior reasoning

Each shape transition was forced by a concrete thing the previous shape
*couldn't do*:
- Shape 0 → Shape 1: "consumer API must not leak kernel mechanisms"
- Shape 1 → Shape F: "Task(executorPreference:) is advisory and
  deadlocks under `Task.sleep`"
- Shape F → Shape B: "preserving `@Witness` testability while getting
  mandatory binding requires the actor to be *inside*, not outside"

Each obstacle was representable only as a concrete compiler message, a
concrete bug number (swift#74395), or a concrete capability loss
(`IO.unimplemented()` stops working). Pre-obstacle reasoning converged on
the *wrong* shape repeatedly. The lesson: I should move to implementation
earlier when the design space has three plausible candidates, because the
compiler will collapse at least one option. Reasoning-to-convergence is
cheaper after the first compile failure than before it.

### Pattern 2: "Compiler limitation" is a first-class design input

Three Swift 6.3 limitations shaped the final design:
- `sending` + `isolated Self` region-checker bug → forced `@Sendable` on
  `Actor.run` bodies
- `Task(executorPreference:)` advisory semantics + swift#74395 → forced
  actor isolation for mandatory binding
- `Kernel.Thread.Executor.Sharded` not conforming to `SerialExecutor` →
  forced per-shard pinning at factory time

Each of these had been treated as a "workaround" rather than a design
constraint in early iterations. Treating them as inputs (same rank as
"must preserve `@Witness` testability") would have collapsed to Shape B
faster. The skill correlate: compiler constraints deserve first-class
slots in a research doc's "Constraints" section, not buried in
"Disadvantages" of individual options.

### Pattern 3: Structural reshuffle beats additive workarounds

The Shape F → Shape B transition wasn't a new *idea*; it was a
*rearrangement* of the same pieces. Same witness, same actor, same
executor. What changed: which type is public, which is internal, and who
holds whom. A structural reshuffle can dodge multiple independent
constraints simultaneously because the constraints applied to one
arrangement of the pieces, not to the pieces themselves.

The warning sign that a reshuffle was due: I was writing "defense-in-depth
mitigations" in the v2 research doc (docstring warnings, debug
assertions, `withTaskExecutorPreference` wrapping). When a design needs
three layered mitigations to cover one weakness, the weakness is
structural.

### Pattern 4: IO Events and IO Completions are the real migration work

Shape B is settled for blocking. The session ended with Events and
Completions *unchanged* — still carrying the pre-witness Loop/Selector/
Queue/Poll architecture. Migrating them to the Shape B pattern (public
`@Witness struct IO` with closures forwarding to an internal Events actor
/ Completions actor) is the remaining work. The skill correlate: whenever
a new pattern lands in one module, other modules that existed before the
pattern are not automatically migrated. Cross-module migration is a
distinct unit of work that needs its own milestone, not a rollup into
"land the pattern."

## Action Items

- [ ] **[skill]** implementation: Add to `[IMPL-066] sending at Isolation Boundaries`
  a note that `sending` does **not** replace `@Sendable` for closure parameters
  to actor methods with `isolated Self` in Swift 6.3 — region-based isolation
  checker errors out with a "please file a bug" diagnostic. Cite:
  `swift-io/Experiments/actor-runner-sending-body/` for repro,
  `HANDOFF-actor-runner-investigation.md:139–152` for full error and
  explanation.

- [ ] **[research]** Should `IO.Events` and `IO.Completions` adopt Shape B
  (`@Witness struct` forwarding to internal actor)? Specifically: does a
  kqueue/epoll event loop fit the single-executor-per-actor model, or does it
  demand a different isolation shape (the event loop thread IS the executor,
  so the actor isn't strictly necessary)? Cross-compare with the retained
  prototypes in `swift-io/Experiments/actor-{borrowing-async,direct-methods}/`.
  Scope: `swift-io/Research/`. Blocks Phase 2.

- [ ] **[package]** swift-io: Document in `Research/io-blocking-executor-binding.md`
  (v4 is the current) that `Kernel.Thread.Executor.Sharded` does NOT conform to
  `SerialExecutor` — only `Kernel.Thread.Executor` does. Pin one shard at
  factory time via `pool._executors.next()` before handing to an actor's
  `unownedExecutor`. Calling `.next()` inside the getter would return
  different executors per call, violating the stability contract
  (`HANDOFF:212–222`).
