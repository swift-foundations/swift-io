---
date: 2026-04-15
session_objective: Resolve Phase 3b of swift-executors complete-toolkit — Polling adapter (A) vs primitives-only refactor (B) for IO.Completion.Loop
packages:
  - swift-io
  - swift-executors
  - swift-executor-primitives
status: processed
processed_date: 2026-04-16
triage_outcomes:
  - type: skill_update
    target: modularization
    description: "Added [MOD-015a] Narrow-imports exception for shadow disambiguation"
  - type: skill_update
    target: implementation
    description: "Added [IMPL-090] Abstraction-Seam Validity Requires Data-Contract Alignment"
  - type: research_topic
    target: proactor-generalization-iocp-windows.md
    description: "Does proactor generalize to IOCP? Primitives-only executor shell vs adapter through Polling"
---

# Completion.Loop: Proactor is a Real Architectural Boundary, Not an Abstraction Seam

## What Happened

Supervisor handoff framed Phase 3b as resolving the Completion.Loop architecture: adapter-wrap the io_uring notification eventfd in a `Kernel.Event.Source` so Polling could own the run loop (Option A), or replace the ad-hoc executor machinery in Completion.Loop with L1/L3 primitives while keeping the 5-phase proactor run loop (Option B). The handoff explicitly said "do not assume Option A is correct" — prior context had drifted toward Option A and the supervisor was correcting.

Read source files to establish ground truth:
- `IO.Completion.Loop.swift` (362 LOC) — 5-phase loop: drain → cancel → flush → poll → dispatch
- `Kernel.Thread.Executor.Polling.swift` (187 LOC) — 3-phase loop: drain → wait → tick
- `IO.Event.Loop.swift` (145 LOC post-migration) — reactor-on-reactor, delegates to Polling, tick dispatches kernel events to channel senders
- `IO.Completion.Driver+Platform.swift:143` — `cs.completion.notification?.wait()` (the blocking primitive)
- `Kernel.Completion.Notification+Wait.swift` — the `wait()` is a blocking 8-byte eventfd read

Wrote `swift-io/Research/completion-loop-executor-unification.md` evaluating both options. The decisive finding: **Option A introduces a flush-before-wait deadlock.** Concretely: Polling's run loop is `drain → wait → tick`, but Completion.Loop requires flush BEFORE the blocking wait (SQEs submitted by actor jobs during drainJobs would never reach the kernel before the blocking epoll_wait blocks). The wakeup fired by `enqueue()` is consumed by the previous `wait` return, so the next `wait` blocks indefinitely on an eventfd that will never fire because no submissions were flushed. A workaround (submit-path wakeup) adds a per-submit syscall and defeats the purpose of the blocking poll. Additionally, the tick would receive Kernel.Events that only say "the eventfd fired" — ignored entirely by the handler, which would always do the same work (cancel → flush → drain → dispatch).

Recommended Option B. Supervisor approved.

Implementation landed in two commits:
- **swift-io `9dcd4142`** (author: external, same session): `IO.Completion.Loop.swift` refactor — `Kernel.Thread.Synchronization<1>` → `Kernel.Thread.Mutex`; `ContiguousArray<UnownedJob>` → `Executor.Job.Queue`; `isRunning: Bool` → `Executor.Shutdown.Flag`; drainJobs simplified via `Queue.drain(into:)` + `while dequeue()`. Also included alignment cleanup for `IO.Event.Loop.deinit` matching swift-executors' `shutdownNow()` → `shutdown()` rename.
- **swift-io `25c6da4f`** (author: this session): `Package.swift` adds swift-executor-primitives dependency + `Executor Primitives` product; research doc added with status COMMITTED.

Compile errors along the way:
1. `_Concurrency.Executor` (stdlib protocol, in scope because Loop conforms to SerialExecutor) shadowed the `Executor` namespace from `Executor_Primitives_Core`, requiring module-qualification.
2. Module-qualifying through the narrow-import product (`Executor_Job_Queue_Primitives.Executor.Job.Queue`) failed — the `Executor` enum is declared in `Executor_Primitives_Core`, which is a target but not a product, and re-exports via `public import` don't promote the re-exporting module to "declares X" status. Had to switch to the umbrella `Executor Primitives` product (`Executor_Primitives.Executor.Job.Queue`) — same pattern Polling uses.

Verification: `swift build` clean (all targets); `swift test` 44 tests / 21 suites green on macOS. Supervisor verified all 6 ground-rule entries and terminated with Success per [SUPER-010]. Stamp added to HANDOFF.md per [SUPER-011].

**Handoff triage (per [REFL-009]):** Scanned 7 `HANDOFF*.md` files at `/Users/coen/Developer/`. Triaged:
- `HANDOFF.md` — this session's Phase 3b dispatch. Next Steps 1-3 complete; #4 (phase gate report) explicitly deferred by supervisor per [SUPER-010]; all 6 ground-rule entries verified; verification stamp added. Deleted (git preserves the stamped final state).
- `HANDOFF-io-completion-migration.md`, `HANDOFF-executor-audit-cleanup.md`, `HANDOFF-executor-audit.md`, `HANDOFF-migration-audit.md`, `HANDOFF-path-decomposition.md`, `HANDOFF-primitive-protocol-audit.md` — not this session's. Left unchanged per [REFL-008] "only this session knows which described work finished." Several carry explicit status markers (SUPERSEDED, unmerged branches, "parent conversation continuing") indicating deliberate preservation by their authors.

## What Worked and What Didn't

**Worked — research-first approach.** The supervisor's `MUST NOT assume Option A` was load-bearing. Without it, pattern-matching from Event.Loop's clean migration ("reactor-on-reactor was easy, so proactor-on-reactor should also work") would have sent the session into Option A, and the flush-before-wait deadlock would have surfaced only at runtime — hours of implementation + debugging + revert. Writing the research doc took ~30 minutes and killed Option A dead on paper.

**Worked — reading actual source (not summaries).** The handoff described the structural differences between reactor and proactor (table on lines 26-31) but did NOT state the phase-ordering constraint (flush MUST precede wait). That invariant only becomes visible when you read the run loop's sequence in Loop.swift and the poll closure's drain/wait/drain pattern in Driver+Platform.swift. If I had trusted the handoff's analysis without reading the source, I would have missed the deadlock.

**Didn't work — narrow-imports first.** Followed `feedback_no_umbrella_imports.md` memory and tried `Executor Job Queue Primitives` as the narrow product. Compile failed because `Executor` is a namespace enum declared in `Executor_Primitives_Core` (target, not product) — the narrow product re-exports types but not module membership, so `Executor_Job_Queue_Primitives.Executor.X` doesn't resolve. Had to fall back to the umbrella `Executor Primitives`. The narrow-imports guidance is correct when types are declared in the product's own target, but fails silently when the type lives in a shared Core target that isn't itself a product. This interaction isn't documented in the narrow-imports memory.

**Didn't anticipate — stdlib name shadow.** `Loop` conforms to `SerialExecutor` and `TaskExecutor`, which makes `_Concurrency.Executor` visible in the class body. The `Executor` namespace enum from swift-executor-primitives was shadowed. Polling has the same conformances and handles this via module-qualification (`Executor_Primitives.Executor.Job.Queue`) — but I didn't recognize this pattern until the compile error forced it. Worth noting: any module that defines an `Executor` namespace will collide with stdlib conformers; module-qualification is not an afterthought, it's structural.

**Process friction — external commit interleaving.** During my implementation, an external commit (`9dcd4142`) landed that re-applied my Loop.swift edits with an authoring message framed around "deinit rename for executor shutdown rename." Didn't realize my implementation was already committed until I ran `git status` and saw the file was clean. Not a problem here (the commit was correct), but a warning: when multiple actors operate on the same working tree in one session, "my edit" vs "committed externally" requires git-status vigilance rather than assuming uncommitted.

## Patterns and Root Causes

### 1. Abstraction seams belong where data contracts align, not where surface shapes suggest

Event.Loop:Polling was a clean migration because both are reactors — they block on the same primitive (`source.poll()`), wake via the same mechanism (event source wakeup), and receive the same type of domain data (kernel events from the poll). The primitives *literally* had the same shape, so delegation worked.

Completion.Loop:Polling has matching *surface* (both are "an executor with a run loop that handles I/O") but mismatching *data contracts*:
- Polling's tick consumes kernel events as its core data
- Completion.Loop ignores kernel events and consumes CQEs from a separate ring buffer

An adapter forcing the proactor through the reactor shell produces code where **the consumer ignores the executor's core output**. The supervisor's framing — "if the consumer ignores the executor's core data contract, the executor model is wrong for this consumer" — generalizes: an abstraction is a candidate seam only when its data flow matches the consumer's needs. Surface-shape similarity is a red herring.

This is the same pattern as Shape 0 → Shape B in the IO witness work (reflection 2026-04-14-io-witness-shape-b-emergence.md): premature unification of reactor+proactor closures into one `@Witness` produced a shape that had to be rejected because the two paradigms don't compose at that layer. The right unification is at the primitives (shared types), not at the shell (shared runtime structure).

### 2. Swift module qualification is about declaration, not visibility

`public import X` in module Y makes X's types visible to Y's consumers. But consumers cannot qualify those types with `Y.TypeName` — only with `X.TypeName`. The re-exporting module is a conduit for visibility, not an owner of the re-exported symbols.

This interacts with two ecosystem conventions:
- **Narrow-imports preference** (`feedback_no_umbrella_imports.md`) — pushes consumers toward the narrowest product.
- **Types declared in Core targets, exposed via sibling products** — the Core target (`Executor Primitives Core`) declares shared namespaces used by all sibling targets (`Executor Job Queue Primitives`, etc.), which re-export it via `public import`.

When you don't need qualification (e.g., no name shadow), narrow imports work fine. When you need qualification for disambiguation, you need a module that *declares* the namespace. The umbrella product works because its target has `@_exported public import` of all siblings — but more importantly, it has access to the declaring module and can be module-qualified as a proxy.

There is no workaround that preserves narrow imports for this case: either make Core a product (explicitly rejected by the user this session — "Executor Primitives Core is no longer a product"), or use a product whose module declares the namespace. The umbrella is the latter by design. This isn't a narrow-imports violation; it's the case the narrow-imports guidance doesn't cover.

### 3. Explicit constraints beat implicit expectations across handoff boundaries

The handoff author had context that the new agent lacked: the reactor/proactor mismatch had been understood during handoff-authoring, but the original dispatch was written before that understanding crystallized. The supervisor's `MUST NOT assume Option A` + the ground-rule `fact` entries transferred this context explicitly.

This is the supervisor/subordinate pattern working as designed (per `/supervise` skill): when the principal knows the subordinate will face pattern-match pressure toward a wrong answer, explicit MUST NOTs short-circuit the pattern match. The cost is trivial (one line per constraint); the savings are hours of dead-end implementation.

Recurring theme across this session and the preceding Phase 3a: **supervisor ground-rules blocks in HANDOFF.md are the highest-leverage intervention the principal has.** The first words of Phase 3b's first agent response set the trajectory. Getting the constraints right before spawning the subordinate pays back every subsequent decision.

## Action Items

- [ ] **[skill]** modularization: Document the narrow-imports exception — `public import X` in a narrow product Y re-exports X's types but does NOT promote Y to "declares X" status for module-qualification. When consumers need `Module.Namespace` syntax for shadow-disambiguation (e.g., `_Concurrency.Executor` vs primitives `Executor`), they need a module that *declares* the namespace — typically the umbrella product. Add as a [MOD-*] exception to the narrow-imports rule.

- [ ] **[skill]** implementation: Add guidance on abstraction-seam validity — "When considering whether to unify two runtime patterns via a shared executor/driver shell, ask whether the consumer would ignore the shell's core data contract. If the answer is yes, unify at the primitives layer, not the shell layer. Surface-shape similarity is not evidence of a valid seam; data-contract alignment is." Target: [PATTERN-*] or new [IMPL-*] on abstraction seams.

- [ ] **[research]** Does the proactor pattern generalize to IOCP (Windows)? If so, does IOCP need its own primitives-only executor shell (like Completion.Loop) rather than being adapted through Polling or a reactor-shaped abstraction? Decision #6 in executor-package-design.md defers IOCP until a Windows consumer exists; this question should be reopened when that happens, with Phase 3b's reactor/proactor analysis as prior art.
