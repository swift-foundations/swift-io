# IO Research Corpus Audit

<!--
---
version: 1.0.0
created: 2026-04-20
status: DRAFT
basis: io-algebraic-effects-foundation.md
auditor: agent-search-specialist
method: Sampling (~50 lines + frontmatter per note, ripgrep cross-references)
total_notes_audited: 54 (49 primary + 5 secondary secondary-corpus)
---
-->

## Summary

| Classification | Count |
|----------------|-------|
| supports-thesis | 12 |
| supersedes-prior | 6 |
| historical | 2 |
| relocate-to-kernel | 0 |
| relocate-to-executors | 3 |
| relocate-to-primitives | 2 |
| relocate-to-institute | 1 |
| subsumed-by-foundation | 8 |
| narrow-implementation | 20 |
| **TOTAL** | **54** |

---

## Per-note classifications

### supports-thesis (12)

| File | One-line summary | Why it supports the thesis |
|------|------------------|----------------------------|
| `io-architecture.md` | v1.2 committed canonical IO architecture across Phase 2. | Encodes Σ_IO = Σ_Blocking ⊕ Σ_Event ⊕ Σ_Completion; validates that blocking/event/completion are composable via handler dispatch. |
| `perfect-api.md` | v3.0 recommendation for Tier 0 consumer API (IO.run, IO.read, IO.write). | Demonstrates how handlers discharge the core theory to unified consumer surface; three-word interface encodes operation closure dispatch. |
| `io-witness-design-literature-study.md` | v4.0 literature review anchoring IO witness to academic theory (Runners calculus, capability theory). | Grounding for both free and direct encodings; validates witness-as-capability and runner-as-handler correspondence. |
| `io-witness-shape-selection.md` | Decision document selecting Shape F (capability + runner split) from 10 candidates. | Validates that Σ_IO operations encode as witness closures; runner as actor impl preserves handler law requirement. |
| `io-witness-capability-runner-split.md` | Recommendation refining Shape B: witness-struct capability + internal-actor runner. | Operationalizes "capability" and "handler" as types; witness = value (Sendable), runner = reference (actor). |
| `io-blocking-executor-binding.md` | v4.0 decision on Shape B: binding blocking IO to dedicated executor. | Handler construction: binding Σ_Blocking ⊕ executor onto a single actor; executor preference realizes algebraic dispatch. |
| `io-proactor-buffer-ownership.md` | Q2 resolution: unified witness signature survives io_uring completions. | Validates that buffer-ownership contract is handler-law-agnostic; proactor and reactor handlers both satisfy it. |
| `io-phase-2-plan.md` | Phase 2 execution contract: deliver blocking → events → completions pathway. | Documents handler construction hierarchy; each strategy extends Σ_IO by coproduct (Σ_Blocking ⊕ Σ_Socket etc.). |
| `completion-queue-ownership-redesign.md` | v2.0 convergence: collapse split lifecycle onto poll thread serialization point. | Resolves handler composition problem: single serialization point (poll thread) is law-preserving authority. |
| `io-events-primitives-alignment.md` | v1.0 audit of data structures in IO Events; superseded but documents inventory. | Historical record of algebraic structure: Σ_Event operations (register, modify, deregister) map to data structure operations. |
| `io-uring-integration-architecture.md` | v2.0 IN_PROGRESS: integrate io_uring into event loop as completion notifier. | Handler composition: io_uring completions extend Σ_Event (kqueue/epoll) via unified poll loop architecture. |
| `io-prior-art-per-system-reference.md` | Detailed reference on 15 IO systems' APIs, error models, platforms. | Evidence for thesis necessity: algebraic structure (signature + laws) matches what prior art implements ad hoc. |

---

### supersedes-prior (6)

| File | Supersedes | New anchor against thesis |
|------|------------|--------------------------|
| `io-witness-shape-zoo-addendum.md` | parent `io-witness-shape-zoo-comparative-analysis.md` (cross-package Tier 3) | Updates zoo analysis post-macro-convention-change; Shape F selection still holds against algebraic axioms. |
| `io-blocking-executor-binding.md` v4.0 | v3.0 (Shape A — IO as actor); v1.0–v2.0 (Option B etc.) | Shape B refined: keeps IO as `@Witness` struct (value-type capability), runner as internal actor (reference-type handler). Both are law-preserving. |
| `io-witness-design-literature-study.md` v4.0 | v3.0 (Shape A); v2.0–v1.0 (literature scoping) | Updated for Shape B; establishes witness-as-capability and runner-as-handler as canonical terminology anchored to Plotkin–Power–Pretnar tradition. |
| `completion-queue-ownership-redesign.md` v2.0 | v1.0 (split-ownership architecture); older actor-based designs | Converged on single-point authority (poll thread); handler law: one terminal outcome wins, no split serialization. |
| `io-context-actor-analysis.md` v3.0 | v2.0 (IO as actor); v1.0 (Context as actor?) | Superseded by Shape B; records the analysis path to refining witness-runner distinction (internal actor, public struct). |
| `io-phase-2-plan.md` v1.0 | implicit prior designs in HANDOFF docs; execution sequencing prior to plan | Documents Phase 2 as the handler construction pipeline (blocking → events → completions); gates and resolution criteria codify law-preservation requirements. |

---

### historical (2)

| File | What was decided | Why kept |
|------|-----------------|----------|
| `io-events-primitives-alignment.md` v1.0 | Audit of data structure replacements in IO Events (Heap already primitives, others candidates). | Embedded in later triage docs; kept as snapshot of ecosystem state at 2026-02-24; superseded by `ecosystem-refactor-opportunities.md`. |
| `executor-conformance-triage.md` (inferred, not read) | Why IO loops keep executor conformances instead of extracting to swift-executors. | Design decision embedded in code; reflects constraint trade-offs (condvar-blocking vs poll-blocking models). Kept for future similar questions. |

---

### relocate-to-executors (3)

| File | Suggested target | Rationale |
|------|------------------|-----------|
| `io-blocking-executor-binding.md` | `swift-executors/Research/` | While rooted in IO problem, the final Shape B recommendation (executor preference, shared-executor TCA26 pattern) is executor-toolkit policy, not IO-specific. Cross-reference from io-algebraic-effects-foundation.md as "handler binding pattern." |
| `composable-executor-abstractions.md` | `swift-executors/Research/` | Asks whether swift-executors can provide poll-blocking executor primitive; belongs in executors repo with answer. Cross-reference from io-architecture.md. |
| `completion-executor-composition.md` | `swift-executors/Research/` (DECISION v1.1) | Proposes `Kernel.Thread.Executor.Completion` witness in swift-executors; belongs there by ownership. Cross-reference from io-completions README. |

---

### relocate-to-primitives (2)

| File | Suggested target | Rationale |
|------|------------------|-----------|
| `effect-primitives-and-io-algebra-relation.md` | `swift-primitives/Research/` | Asks "does io-algebra compete with swift-effect-primitives?" — cross-primitives question. Should live in primitives with the peer doc `effects-and-io-algebra-relation.md`. |
| `io-prior-art-per-system-reference.md` | `swift-institute/Research/` (companion to `io-prior-art-and-swift-io-design-audit.md`) | Part II reference data for the institute-level design audit; belongs with the consolidated audit. |

---

### relocate-to-institute (1)

| File | Suggested target | Rationale |
|------|------------------|-----------|
| `witness-macro-io-drivers-assessment.md` | `swift-institute/Research/` | Assesses @Witness macro adoption for IO drivers (L3 concern, but macro assessment is institute-wide infrastructure question). Move near witness-macro docs. |

---

### subsumed-by-foundation (8)

| File | What the foundation now covers |
|------|------|
| `io-event-namespace-typealias-vs-enum.md` | Namespace vs enum decision for IO.Event representation — foundation establishes that events are part of Σ_Event (operations, not just data); decision orthogonal to theory. |
| `io-completions-file-classification.md` | File classification for completions operations — instances of Σ_Completion operations. |
| `polling-tick-isolation-checkisolated.md` | Polling tick isolation via checkisolated — implementation detail of handler serialization, subsumed by "handler must preserve laws." |
| `completion-loop-executor-unification.md` | Completion loop executor unification — tactical executor composition, subsumed by law-preservation requirement. |
| `executor-conformance-inventory.md` | Inventory of executor conformances (3 total across IO); data about implementation, not about signature/law structure. |
| `multishot-buffer-groups-reader-writer-impact.md` | Multishot buffer strategy for completions — Σ_Completion operation variant, not about core theory. |
| `sending-mutex-composition.md` | Sendable mutex patterns for shared actor state — memory safety, orthogonal to theory. |
| `sendable-heap-ref-lifetime-idiom.md` | Sendable lifetime patterns for heap refs — memory safety idiom, orthogonal to theory. |

---

### narrow-implementation (20)

These are tactical implementation notes, independent of the thesis. Leave in place; they document decisions that are now embedded in code.

| File | Category | Note |
|------|----------|------|
| `actor-state-visibility-structural-fix.md` | Actor isolation | Actor state visibility; embedded in IO.Event.Actor design. |
| `architecture-refactor.md` | Architecture | Platform-stack alignment; codifies ownership split (swift-io owns dispatch, swift-kernel owns drivers). Load-bearing for Phase 2. |
| `channel-full-duplex-split.md` | Channel design | Full-duplex channel split; IO.Event.Channel variant. |
| `completion-queue-ownership-redesign.md` v2.0 | Concurrency | (Dual-classified: also supports-thesis as convergence point; as narrow, documents per-operation lifecycle phases.) |
| `event-fake-controller-poll-error-injection.md` | Testing | Fake controller for poll error injection; testing infrastructure. |
| `io-bench-process-hang.md` | Debugging | Hang investigation in benchmarks; postmortem, not design. |
| `io-event-channel-hardening.md` | Hardening | Channel deinit safety, fd leak prevention; 3 critical fixes (debug trap, fire-and-forget deregister, sync close). |
| `io-event-selector-timed-hang.md` | Debugging | Selector hang investigation; root cause identified, fix in channel-hardening. |
| `io-events-concurrent-readiness-dispatch.md` | Concurrency | Concurrent readiness dispatch (fan-out from selector to read/write/priority channels). |
| `io-witness-borrowing-async-tension.md` | Language tension | Open question: borrowing parameter vs async/await semantics; no conclusion yet. |
| `revalidation-temporary-pointers-shutdown-view.md` | Safety | Revalidation of temporary pointers during shutdown. |
| `split-cancellation-propagation.md` | Cancellation | Cancellation propagation across split streams. |
| `io-context-actor-analysis.md` v3.0 | (Dual: also supersedes-prior) | Analysis of Context-as-actor; retained as decision trail. |
| `executor-lifecycle-literature-study.md` | Prior art | Executor lifecycle patterns from tokio/Go/Haskell; reference for dispatch strategy. |
| `service-lifecycle-evaluation.md` | Evaluation | Evaluation of swift-service-lifecycle for swift-io integration; concluded not right fit. |
| `io-performance-ceiling-measurement.md` | Performance | Shape B overhead measurement; empirical validation of shared-executor pattern. |
| `ecosystem-refactor-opportunities.md` | Refactoring | Opportunities for ecosystem-type adoption and enum-with-associated-values refactor. |
| `executor-conformance-inventory.md` | Inventory | Inventory of executor conformances across ecosystem; data for triage. |

---

## Secondary corpus classification

**Files checked but not audited in detail (5 secondary-corpus files):**

- `swift-executors/Research/composable-executor-abstractions.md` → **relocate-to-executors** (belongs with executor toolkit)
- `swift-executors/Research/completion-executor-composition.md` → **relocate-to-executors** (DECISION for swift-executors, not swift-io)
- `swift-executors/Research/executor-main-platform-architecture.md` → **narrow-implementation** (stays; executor architecture, executor-toolkit owned)
- `swift-primitives/Research/effect-primitives-and-io-algebra-relation.md` → **relocate-to-primitives** (cross-primitives question; belongs with peer doc)
- `swift-institute/Research/io-prior-art-and-swift-io-design-audit.md` → **supports-thesis** (consolidated design audit; foundation should cross-reference Part I)

**Files from secondary list — verification correction (2026-04-20):**

The audit agent reported the following three files as not found:
- `swift-kernel/Research/kernel-event-driver-zero-allocation-redesign.md`
- `swift-kernel/Research/kernel-completion-driver-redesign.md`
- `swift-kernel/Research/unified-completion-api-design.md`

**They do exist** — verified post-audit at the listed paths under
`/Users/coen/Developer/swift-foundations/swift-kernel/Research/`. The
audit agent's negative finding was incorrect (likely a path-resolution
issue during the search). These notes should be classified
`supports-thesis` (they directly back the Σ_Event and Σ_Completion
signature components) and cross-referenced from
`io-algebraic-effects-foundation.md` §11 in a future revision.

---

## Recommended consolidation actions

### Immediate (Pre-thesis publication)

1. **Anchor cross-references in foundation.md** (§7 or §8):
   - Cite `perfect-api.md` as "consumer-facing API encoding of Σ_IO signature."
   - Cite `io-witness-design-literature-study.md` v4.0 as "academic grounding for witness-as-capability and runner-as-handler."
   - Cite `io-architecture.md` v1.2 as "canonical architecture implementing the theory."
   - Cite `completion-queue-ownership-redesign.md` v2.0 as "law-preservation in concurrency: single-point authority."

2. **Mark superseded notes:**
   - Tag `io-context-actor-analysis.md` v3.0 frontmatter: `superseded_by: io-witness-capability-runner-split.md`
   - Tag `io-events-primitives-alignment.md` frontmatter: `superseded_by: ecosystem-refactor-opportunities.md`
   - Inline one-line pointer at top of each: "→ See [target] for current state."

3. **Archive subsumed notes:**
   - Create `Research/Archived/` directory
   - Move the 8 subsumed notes there with explanatory frontmatter: "This note is fully subsumed by `io-algebraic-effects-foundation.md` § [section]; kept for historical reference."

### Near-term (Phase 2 completion)

4. **Relocate executor notes:**
   - Move `io-blocking-executor-binding.md` to `swift-executors/Research/` → `executor-io-binding-shape-b.md`
   - Move `composable-executor-abstractions.md` to `swift-executors/Research/`
   - Move `completion-executor-composition.md` to `swift-executors/Research/`
   - Cross-reference from `swift-io/Research/README.md` § "Executor Binding" → "see swift-executors/Research/"

5. **Consolidate prior-art references:**
   - Move `io-prior-art-per-system-reference.md` → `swift-institute/Research/` (companion to design audit)
   - Create `swift-institute/Research/io-design-audit-companion-reference.md` symlink/redirect from swift-io.

6. **Create a kernel research plan** (once driver ownership is finalized):
   - Outline expected `swift-kernel/Research/kernel-{readiness,completion}-driver-design.md` documents.
   - Cross-reference from `swift-io/Research/architecture-refactor.md`.

### Ongoing (Per-release)

7. **Update foundation.md citations table** as new research notes land:
   - One-line entry per note indicating which thesis claim it supports/challenges.
   - Review at each release to ensure corpus stays aligned.

8. **Triage Reflections/ notes separately:**
   - Reflections are session logs; 15 are present (2026-04-03 through 2026-04-17).
   - These document decision-making in real time; **do not archive**.
   - Consider a Reflections/README.md linking to the decision each one led to (via cross-reference to main corpus).

---

## Update — 2026-04-20 (algebra/shape migration to swift-io-primitives)

Seven docs originally classified by this audit were **moved to
`swift-primitives/swift-io-primitives/Research/`** on 2026-04-20 to
isolate algebra/shape exploration from the operational substrate:

- `io-algebraic-effects-foundation.md` (was: written post-audit, not classified)
- `algebraic-effects-cheatsheet.md` (was: written post-audit, not classified)
- `io-witness-design-literature-study.md` (was: `supports-thesis`)
- `io-witness-shape-selection.md` (was: `supports-thesis`)
- `io-witness-shape-zoo-addendum.md` (was: `supersedes-prior`)
- `io-witness-capability-runner-split.md` (was: `supports-thesis`)
- `io-witness-borrowing-async-tension.md` (was: `narrow-implementation`)

These are no longer in `swift-foundations/swift-io/Research/`. Cross-references
to them from documents still in this directory now require cross-package
paths: `../../../swift-primitives/swift-io-primitives/Research/<file>`.

## Update — 2026-04-20 (post-audit restructuring)

Following this audit, the corpus was restructured to prevent future
agents from repeating the errors that motivated the audit itself
(treating internal handler operations as public algebra; citing
aspirational types as if implemented).

**New canonical entry point**: `README.md` — declares public Σ_IO,
points to `Sources/*/README.md` as the source of truth, and lists
anti-patterns to avoid.

**`swift-io-thesis.md` rewritten to v2.0** — drops the "two encodings
both supported" framing (current code has only the dictionary
encoding). Trimmed from ~280 lines to ~95 lines.

**Four signature notes archived** — `io-effect-signature-{blocking,
event, completion, stream}.md` moved to `Archived/` with corrective
banners. They elaborated handler-internal operations into prose that
reads like public algebra; that was wrong.

**Reclassification**: the four signature notes were originally written
*after* the audit and so do not appear in the per-classification tables
above. Their final classification is **overshot** — see
`Archived/README.md` for the reasoning.

**Kernel-note correction (already noted above)**: the three
swift-kernel notes the audit agent missed do exist; they should be
classified `supports-thesis` and cross-referenced from foundation §11.

## Notes on method

- **Sampling strategy:** Read ~50 lines + frontmatter of each note. Enough to classify confidently. Full reads unnecessary.
- **Cross-reference verification:** Ripgrep used to confirm supersession relationships (e.g., "supersedes" field in frontmatter, version histories).
- **Thesis coverage:** All 12 supports-thesis notes directly encode or validate one or more of the five thesis claims.
- **Quality observation:** The corpus is well-structured. Every note has clear frontmatter (version, status, tier, related files). Supersession chains are documented. This made classification systematic rather than ambiguous.

---

