---
date: 2026-04-16
session_objective: Simplify IO Completions following IO Events/Blocking patterns — delegation to kernel types and swift-executors
packages:
  - swift-io
  - swift-executors
  - swift-kernel
  - swift-sockets
status: processed
processed_date: 2026-04-24
triage_outcomes: see reflections-processing run 2026-04-24
---

# IO Completions: Full Delegation and Simplification (28 → 8 source files)

## What Happened

Reduced IO Completions from 28 source files to 8 across seven commits in swift-io, two in swift-executors, one in swift-kernel, one in swift-sockets. The refactor followed the same two-delegation pattern IO Events used: (1) delegate the witness layer to the kernel (`typealias IO.Completion = Kernel.Completion`), and (2) delegate the executor to swift-executors (`Kernel.Thread.Executor.Completion`).

Phase 1 (witness delegation): deleted the L3 `IO.Completion.Driver` witness cascade (Driver, Handle, Capabilities, Platform), L3 error hierarchy, and parallel Kind/Flags/Event types. IO.Completion became a namespace adoption of Kernel.Completion.

Phase 2 (executor delegation): introduced `Kernel.Thread.Executor.Completion` in swift-executors — a proactor sibling to Polling. Collapsed IO.Completion.Loop + IO.Completions struct + IO.Completions.Actor into a single public `IO.Completion.Actor`. The naming debate settled on "Completion" (mechanism word, symmetric with "Polling") rather than "Proactor" (pattern word).

Subsequent passes: deleted Outcome/Success types (raw kernel Event through, consumer interprets per [IMPL-092]); deleted typealias bridges (Kind, Flags, ID — use kernel types directly); collapsed single-inhabitant Cancellation namespace; deleted dead State enum; deleted rawDescriptor escape hatch; eliminated all `@_spi(Syscall)` by pushing `Event.Result.failure` to L3 swift-kernel.

A supervised subordinate then eliminated IO.Completion.Storage entirely — the retained-pointer custody class that existed because `checkCancellations` removed entries before CQE arrival (causing UAF on the dup'd fd). The subordinate's fresh-take investigation proved: (a) `CheckedContinuation<Event?, Never>` eliminates the result-slot purpose, (b) eliminating `checkCancellations` (flag check moves to dispatch) eliminates the retained-pointer purpose. Entries survive in the dictionary until CQE arrival — no Unmanaged, no passRetained.

The subordinate also found a latent token-correlation bug: Phase 1 deleted `translateEvent` (which converted pointer→counter) but left the dispatch looking up entries by pointer. Counter ≠ pointer → `entries.remove` never finds the entry on the io_uring path. Masked by macOS-only test coverage.

## What Worked and What Didn't

**Worked — the two-delegation pattern.** Mirroring IO Events' structure (typealias + executor) gave a clear architectural target. Each phase had a well-understood shape because Events had done it first.

**Worked — user's diagnostic observation.** The user saw that `Kernel.Completion` already provides the io_uring/IOCP unification (parallel to `Kernel.Event`), so IO Completions building a second witness on top was redundant. This reframed the scope from "collapse the struct wrapper" to "delete the entire L3 witness layer." The prior handoff (Option B, struct-collapse-only) was too conservative.

**Worked — the supervised fresh-take handoff.** The subordinate derived Storage's eliminability from first principles and found a latent bug the prior session missed. The supervision ground rules (especially #2 "MUST NOT assume Storage is necessary") set the right frame — start from the question, not from the prior answer.

**Didn't work — cached-build masking.** swift-sockets tests passed with cached `.build` but hung with clean rebuild. A pre-existing half-close test hang was invisible until the clean build forced recompilation. The bisect confirmed it predates all session work, but the false "4/4 pass" gave misleading confidence.

**Worked — layering discipline.** User's "swift-executors should NOT have ANY knowledge of IOCP/IO_Uring" reframed the research. The Completion executor takes `Kernel.Completion` (unified primitive) and names no backend — symmetric to how Polling takes `Kernel.Event.Source`. The `Event.Result.failure` property went to L3 swift-kernel (where `@_spi(Syscall)` is appropriate) rather than L3 swift-io.

## Patterns and Root Causes

### 1. Two-delegation yields structural symmetry

The Events → Completions migration proved the pattern: (a) adopt the kernel type via typealias, (b) delegate executor to swift-executors. Both strategies now have identical public shape: a single actor holding an executor. The pattern is transferable to any future IO strategy.

### 2. Retained-pointer patterns are often compensation for early-removal bugs

Storage existed because `checkCancellations` removed entries before CQE arrival. The Unmanaged.passRetained trick compensated for a structural flaw (early removal of owned resources). The fix: don't remove early. The dictionary IS the lifetime manager. This generalizes: when you see Unmanaged self-retention in Swift, ask whether the ownership model is wrong, not whether the retention is correct.

### 3. Mechanism-word naming for executors

"Polling" (mechanism) vs "Reactor" (pattern). "Completion" (mechanism) vs "Proactor" (pattern). The executor's name should describe WHAT it does, not WHICH I/O paradigm it serves. This keeps swift-executors general-purpose. The user noted further tension: even "Polling" and "Completion" tie to Event/Completion domains. Post-session revisit.

## Action Items

- [ ] **[research]** swift-sockets half-close test hang: pre-existing, bisected to before this session. Needs a dedicated investigation to determine whether it's a test bug or a real I/O hang in the events strategy on Darwin.
- [ ] **[skill]** implementation: Consider adding guidance on "Unmanaged self-retention is a code smell for wrong ownership boundaries" based on pattern #2.
- [ ] **[research]** swift-executors naming philosophy: user flagged "Polling" and "Completion" still tie executors to Event/Completion domains. Explore whether a more domain-agnostic naming exists that preserves the mechanism-word principle.
