---
date: 2026-04-14
session_objective: Supervise swift-io implementation across design reconsiderations, external reviews, performance measurement, and fate-doc commitment
packages:
  - swift-io
  - swift-witnesses
  - swift-sockets
status: processed
processed_date: 2026-04-16
triage_outcomes:
  - type: skill_update
    target: handoff
    description: "Added [HANDOFF-014] Pre-Existing Code in Scope — handoffs must enumerate Preserved/Refactored/Deleted/Moved pre-existing code"
  - type: no_action
    description: "Measurement discipline for architectural claims — spirit captured in implementation's call-site-first design; not promoted to new requirement"
  - type: research_topic
    target: converged-scope-annotation-protocol.md
    description: "Scope-annotation protocol for CONVERGED outcomes — how to signal prior decisions need re-audit when scope generalizes"
---

# IO Design Review Cycle — Elided Elephant, Measurement Flip, Framing Layering

## What Happened

Session continued from the morning's Shape B emergence reflection. Acted as supervisor across a long iteration:

**Design reconsiderations.** Shape B was "committed" after `/collaborative-discussion` but then reopened repeatedly:
- First as "should we provide both Shape B AND IO.run PF-style?" (user push on PF ergonomics)
- Then "should we go fully PF-only under IO.run?" (collapse toward single entry)
- Then "wait — IO.File, IO.Socket, IO.Pipe as resource witnesses?" (Plan agent suggested layering)
- Then user pushback: "We have swift-file-system, swift-sockets. Higher-level packages build on top. swift-io stays primitive."

Landed on a two-witness minimum (`IO` + `IO.Socket`) with accept forced onto `IO.Socket` because strategy-dispatch is socket-specific. Everything else (File, Pipe, streams) out of scope for swift-io.

**Fresh-perspective review.** User handed the updated handoff to another agent for review. The reviewer caught a critical gap: the handoff treated `IO Events` and `IO Completions` as "Phase 2/3 roadmap items" but the repo contained ~100 files of pre-Shape-B runtime code there — `IO.Event.Channel` (a ~Copyable consumer-facing type with half-close/split/shutdown), `IO.Event.Selector`, `IO.Event.Runtime`, `IO.Completion.Queue`, etc. The handoff had elided this entirely. The reviewer called it the "load-bearing unaddressed question."

**Performance measurement.** The reviewer also challenged my "accept 3.9 µs per-op, document it, Phase 5+ research" position (Item 6). I conceded partial overreach — "swift-sockets CANNOT be tokio-competitive. Period." was unmeasured hyperbole — and recommended a four-configuration benchmark before committing Framing E. Implementing agent ran `Experiments/io-stacked-actor-bench/`:

| Config | Mean ns/op |
|:------:|-----------:|
| Raw syscall | 337 |
| Plain actor + syscall | 2,780 |
| Shape B unshared (cross-hop) | 5,198 |
| **Shape B shared-executor (TCA26)** | **320** |

The shared-executor path came in at 0.95× raw syscall cost. My architectural "ceiling" claim was wrong by two orders of magnitude — TCA26 elides the hop in realistic stacked use. The 3.9 µs number from `actor-hop-benchmark` was a no-op result; with real syscall work, the default-path cost becomes noise against the syscall.

**Fate doc committed.** After measurement, implementing agent drafted `Research/io-events-completions-fate.md` committing to Framing E: delete consumer-facing `IO.Event.Channel` + satellites (move to swift-sockets), retain `Selector/Runtime/Loop/Driver` as `package`/`@_spi`. Caught three corrections in final review:
- `Kernel.Socket.Accept.accept` returns a `Result` struct, not a bare descriptor — need `IO.Socket.Accepted { descriptor, peer }` wrapper
- SE-0386 `package` doesn't cross Swift package boundaries — needs `@_spi(...)` for swift-sockets to access swift-io's retained runtime
- `swift-sockets` is a real (LICENSE-only stub) package — the migration destination exists, shouldn't be "delete" framing

Ended with fate doc correction pass queued, swift-sockets bootstrap queued, handoff amendment queued. No Sources/ changes this session — design layer only.

**Handoff triage at session end** (per [REFL-009]):

| File | Session relevance | Triage outcome |
|------|-------------------|---------------|
| `HANDOFF-io-layered-implementation.md` | Active; Phase 1 pending | Keep — implementing agent's next action is amendment pass |
| `HANDOFF-io-shape-b-implementation.md` | Superseded by layered handoff earlier today | Keep — explicit SUPERSEDED header already present; decision trail useful |
| `HANDOFF-io-layered-implementation-review.md` | Review complete; response written | Keep — historical record of fresh-perspective advisory |
| `HANDOFF-io-layered-implementation-review-response.md` | Response complete | Keep — reference for handoff amendment items |
| `HANDOFF-io-performance-measurement-response.md` | Response complete; measurement resolved Item 6 | Keep — reference for fate-doc commitments |
| `HANDOFF-actor-runner-investigation.md` | Prior-session investigation record referenced throughout | Leave (prior session's artifact) |

Nothing deleted. All session-output handoffs either (a) have pending action items ahead of them, or (b) serve as reference material for the just-drafted fate doc + upcoming amendment. Prior-session handoffs (HANDOFF.md and others) left untouched — this session lacks context to evaluate their completion.

No audit findings to update ([REFL-010]) — `/audit` was not invoked in this session.

## What Worked and What Didn't

**Worked:**
- **Multi-agent review was genuinely productive.** `/collaborative-discussion` (ChatGPT) + Plan-agent (fresh framing) + fresh-perspective review (another session) each caught different issues. Three independent perspectives exposed blind spots the main session couldn't see on its own.
- **Challenge-through-measurement**. When the reviewer challenged my performance claim, the right response wasn't defense — it was spec a four-config benchmark. Data resolved the disagreement cleanly.
- **Supervisor discipline when explicitly framed as supervisor.** Catching `package`-doesn't-cross-boundaries (SE-0386) was legitimate supervisor work — flagged a real bug in the implementing agent's proposal before code commits. Similarly: flagging `Kernel.Socket.Accept.accept` returns a `Result` not a raw descriptor.

**Didn't work:**
- **Handoff elided 100 files of existing code.** The "Phase 2 — internal actor wrapping Kernel.Event.Selector" line treated a major refactor as a one-line roadmap item. Happened because the investigation was blocking-scoped and the generalization to full-public-API didn't widen scope. Fresh review caught it; without that review, Phase 2 would have hit the collision in execution.
- **Quoted performance numbers as analysis.** I said "3.9 µs is a ceiling" and reasoned from there — but "3.9 µs" was a no-op microbenchmark result, and the interesting question (real syscall work, realistic stacked actors) was never measured until the implementing agent asked. My architectural reasoning was sophisticated and empirically wrong.
- **Overreach in supervisor advice.** "swift-sockets CANNOT be tokio-competitive. Period." was confident and unmeasured. Supervisor role was meant to challenge/verify, not propose unmeasured conclusions.
- **Design-by-consensus staleness**. `/collaborative-discussion` converged on Shape B. Subsequent sessions reopened the question (PF-style revisit, layered framing, primitive-vs-layered debate). A `CONVERGED` outcome was treated as more durable than it actually was once scope widened.

## Patterns and Root Causes

**Pattern 1 — Elided-elephant in handoffs.** A handoff scoped to fix one specific problem (blocking binding) became the input for a plan with broader scope (full public API redesign). The handoff's scope-narrow investigation record got carried forward; the plan's scope-broad intent didn't. Result: 100 files of existing runtime code treated as "Phase N roadmap" when they're pre-existing production code needing refactor. The pattern will repeat whenever investigations scope narrowly but conclusions apply broadly, UNLESS handoffs are forced to enumerate pre-existing code in the expanded scope.

**Pattern 2 — Architectural reasoning without measurement.** "3.9 µs is a structural ceiling" felt like analysis but was pattern-matching from a no-op benchmark to a real-workload conclusion. The measurement discipline was always "when an architectural decision hinges on a performance claim, measure in the relevant regime first" — I violated that because the no-op number felt authoritative enough to reason from. It wasn't. The 0.95× raw syscall result would have upended the entire "Phase 5+ performance research" framing I had proposed. Fix: when reasoning toward a ceiling/floor claim, require measurement in the workload that matters, not the microbenchmark regime.

**Pattern 3 — Convergence decay on scope expansion.** `/collaborative-discussion` is a snapshot of agreement at a specific scope. When scope grows (e.g., "fix blocking" → "redesign full API"), the convergence doesn't automatically extend. This session's Shape B CONVERGED outcome got reopened three times — each time the scope had shifted. Treating CONVERGED as permanent creates false confidence. A consensus record should include scope annotation ("converged on the question of advisory-vs-mandatory binding for .blocking()"), not just the outcome.

**Meta-observation**: the biggest session-level mistake was defending positions I had reasoned into, rather than inviting verification. When the reviewer said "3.9 µs might be a ceiling or might be an adoption question — let's measure," I initially wrote "accept 3.9 µs for v1" as a defensive frame. The better supervisor response was "good point, measure before committing." The supervisor role is challenge-and-verify, not propose-and-defend.

## Action Items

- [ ] **[skill]** handoff: When a handoff's scope extends beyond what the underlying investigation directly examined (e.g., investigation scoped to one module, plan applies to whole package), require an explicit "Pre-existing code in scope that this plan does NOT directly modify" section enumerating those files or modules with their intended treatment (Preserved / Refactored in Phase N / Deleted / Moved). Exemplar: this session's handoff missed 100 files of `IO Events` / `IO Completions` code until fresh review caught it.

- [ ] **[research]** Measurement discipline for architectural performance claims: when a design decision hinges on "X is a structural ceiling" or "Y is cost-dominant," require measurement in the workload that matters (not a no-op microbenchmark) before the decision lands. Tier 2 research doc capturing the 3.9 µs → 320 ns flip from this session as exemplar, with methodology notes (four-config benchmark: raw / plain-actor / shape-B-unshared / shape-B-shared).

- [ ] **[skill]** collaborative-discussion: Add a scope-annotation requirement — CONVERGED outcomes should name the specific question that converged (e.g., "converged on advisory-vs-mandatory binding for `.blocking()`"), not just the answer. When subsequent work extends scope beyond the original question, the skill should prompt re-verification rather than treating the prior convergence as permanent. Exemplar: this session reopened Shape B three times because scope expanded without the convergence being re-checked.
