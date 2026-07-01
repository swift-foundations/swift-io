---
date: 2026-04-14
session_objective: Extract Kernel.Thread.Pool to new swift-threads; migrate thread-coordination stack from swift-kernel with fine-grained per-type targets; introduce Kernel.Thread.ID per-L2 platform; remove raw-platform imports from swift-io.
packages:
  - swift-io
  - swift-executors
  - swift-threads
  - swift-kernel
  - swift-darwin-standard
  - swift-linux-standard
  - swift-windows-standard
status: processed
processed_date: 2026-04-16
triage_outcomes:
  - type: skill_update
    target: platform
    description: "Added [PLAT-ARCH-015] Per-L2 platform-native typed values (Kernel.Thread.ID: UInt32/Int32/UInt32 for Darwin/Linux/Windows)"
  - type: no_action
    description: "Tighten IMPL-020 on Property<Tag,Base> — scope-limit rule preserved as design judgment, not new requirement"
  - type: research_topic
    target: thread-dispatch-taxonomy-for-taskexecutor.md
    description: "Thread-dispatch taxonomy for TaskExecutor conformance"
---

# Strict-mission thread-layer refactor

## What Happened

Multi-phase architectural refactor applying the strict-mission principle to the thread-layer boundary across three Layer-3 packages and three Layer-2 platform standards.

**Phase A**. Extracted `IO.Blocking`'s admission-gated closure-dispatch API out of swift-io. Created new L3 package `swift-threads` with `Kernel.Thread.Pool` (admission + dispatch) as its first target. swift-io's `IO.Blocking` collapsed to a shard provider for the witness impl actor — 7 files / ~380 LoC deleted (Run, Error, Metrics, Handle-era leftovers, dispatch tests, IO.Run.Blocking umbrella, IOBenchmarkFixture). `IO Blocking` target's dep count dropped from 6 to 2.

**Phase B**. Migrated `Kernel.Thread.Synchronization` + `DualSync` + `SingleSync` + `Barrier` + `Gate` + `Semaphore` + `Worker` (21 files) from swift-kernel to swift-threads. Fine-grained per-type target decomposition: six variant targets (`Thread Synchronization`, `Thread Barrier`, `Thread Gate`, `Thread Semaphore`, `Thread Worker`, `Thread Pool`) + a `Threads` umbrella. swift-executors rewired to depend on the narrow `Thread Synchronization` product for `Kernel.Thread.Executor`'s internal sync. Cycle avoided because swift-executors imports product-narrow, never the umbrella or `Thread Pool`.

**Thread.ID fix**. Introduced `Kernel.Thread.ID` per-L2 platform (`Darwin.Kernel.Thread.ID` UInt32 mach_port_t, `Linux.Kernel.Thread.ID` Int32 pid_t, `Windows.Kernel.Thread.ID` UInt32 DWORD). Added `swift_gettid()` shim in `CLinuxKernelShim` dispatching `syscall(SYS_gettid)` because SwiftGlibc's module map doesn't expose `gettid()`. swift-io's `IO.Blocking.Actor` replaced `currentThreadID() -> UInt64` + `#if canImport(Darwin) / Glibc / Musl` + raw `internal import Darwin/Glibc/Musl` with `var id: Kernel.Thread.ID { Kernel.Thread.ID.current }`. Resolved pre-existing [PATTERN-004a] + [PLAT-ARCH-008a] + [API-NAME-002] violations. `Windows.Kernel.Thread.currentID()` marked deprecated pointing to the new API.

**Verification**. 191 tests green on macOS arm64 (swift-kernel, swift-threads 35, swift-executors 18, swift-io 138). Linux Swift 6.3 via Docker: swift-io's 138 tests green (required `swift build -j 1` due to a pre-existing SwiftPM parallel-build race on Linux — ecosystem-level, unrelated to this work).

Commits landed across seven package repos. Plan doc at `/Users/coen/.claude/plans/purrfect-juggling-tide.md`.

## What Worked and What Didn't

**Worked**:
- Per-L2 platform-native typed values landed cleanly. Each platform owns its `Kernel.Thread.ID` with the Swift stdlib int type matching the native ABI (mach_port_t → UInt32, pid_t → Int32, DWORD → UInt32). No L1 type, no conditional, no lossy UInt64 middle-layer.
- Fine-grained target decomposition gave every consumer an honest dep graph. swift-executors and swift-io's IO Events each declare just `Thread Synchronization`, not the umbrella.
- Product-level cycle break: swift-executors ↔ swift-threads via narrow product only, SPM resolves without a package-level cycle.
- Deleting more than adding: the swift-io slimming was roughly 380 LoC out, ~15 LoC in.

**Didn't work first time**:
- Thread.ID design took three passes. Uniform UInt64 at L1 (lossy), per-L2 with `rawValue: mach_port_t` (public-property-from-internal-import error), finally per-L2 with `rawValue: UInt32`/`Int32` (Swift stdlib types that 1:1 match the native typedefs without leaking them).
- Proposed `Kernel.Thread.Executor.Thread` as a nested accessor tag — user flagged `Kernel.Thread.*` path repetition as awkward. Dropped the nested accessor entirely; the actor's direct `.id` property is the right shape.
- Proposed `Property<Tag, Base>` for `executor.thread.id` — user asked why that pattern rather than a struct. Answer: [IMPL-020] scopes `Property<Tag, Base>` to verb-like operation namespaces with callAsFunction / multi-method extensibility. `.thread.id` is a noun accessor with one read-only property. Not a fit. I over-generalized past the pattern's stated scope.
- Proposed compound names `threadID` / `currentThreadID` — user caught both. [API-NAME-002] pre-check got skipped when moving fast.
- `@inlinable` + `internal import Darwin` rejects the body when raw types like `mach_port_t` / `pthread_self` are referenced. Dropped `@inlinable` on sampling methods.
- Linux `gettid()` isn't visible through SwiftGlibc — added a C shim. Matched the existing `swift_sched_setaffinity` / `swift_pipe2` pattern in CLinuxKernelShim.

## Patterns and Root Causes

**Ecosystem pattern scope is the rule, not the pattern's popularity.** I proposed `Property<Tag, Base>` for a noun accessor because swift-io's `IO.Blocking.Run` uses it. But [IMPL-020]'s statement restricts the pattern to *verb-like operation namespaces*. Transferring the pattern without re-reading its stated scope was the error. Future guard: when reaching for a known pattern, re-read its Statement before applying.

**Pragmatic REDEFINE decisions are time-bombs when principled reconsideration is possible.** The 2026-04-08 `kernel-type-relocation.md` chose REDEFINE for the thread-coordination stack on pragmatic grounds ("no external consumers"). Six days later the user overrode that on the strict-mission principle. The research doc's framing ("RECOMMENDATION: stay") obscured that the stay was pragmatic, not principled. Framing matters: "deferred pending strict-mission reconsideration" would have signaled the time-bomb; "RECOMMENDATION: REDEFINE" implied settled. Generalization: when a decision cites "no consumers today" as rationale, the label should flag reversibility, not imply stability.

**Platform-native ABI fidelity > uniform portable types** for values that genuinely differ per platform. The instinct to unify (UInt64 everywhere) hides real differences: `mach_port_t` is a Mach kernel concept, `pid_t` is the Linux tid namespace, `DWORD` is a Win32 scheduler concept. Forcing them into one type via bit-pattern conversion is lossy AND misrepresents the platform reality. Per-L2 definition with native int widths (expressed in Swift stdlib types to avoid leaking C typedefs) honors both the platform and the type-system hygiene rules.

**Compound-name vigilance drops under momentum.** I proposed `threadID`, `currentThreadID`, `Kernel.Thread.Executor.Thread` in sequence, each caught by the user. When iterating on a design in a chat session, the naming-convention pre-check is the first corner cut. Future work: a mental two-second pre-check before proposing any new identifier — noun-noun compound? nested path repeating the same word? Both are [API-NAME-00*] violations, both should fail fast.

**Fine-grained modularization is the default, not the optimization.** When I proposed Phase B's target layout I initially bundled Synchronization / Barrier / Gate / Semaphore / Worker into one target. User corrected: each type-family gets its own. The existing `feedback_fine_grained_modularization.md` memory already encoded this, but I defaulted to the pragmatic bundle. Generalization: for multi-type L3 packages, "one target per type-family + umbrella" is the default; bundling is the exception requiring justification.

## Action Items

- [ ] **[skill]** platform: Add a pattern section for per-L2 platform-native typed values — when a type's raw representation genuinely differs per platform (thread IDs, process-level identifiers, etc.), define the type per L2 platform package with the native int width (expressed in Swift stdlib types to avoid leaking C typedefs). Reference `Kernel.Thread.ID` and `Kernel.Process.ID` as precedents. Contrast with the Shell + Values OptionSet pattern ([PLAT-ARCH-013]), which suits types that share an abstract concept but differ in constants.

- [ ] **[skill]** implementation: Tighten [IMPL-020] — Property<Tag, Base> is for verb-like operation namespaces with callAsFunction / multi-method extensibility. Add an explicit "Do NOT apply to" section covering single-property noun accessors, with the `executor.thread.id` counter-example showing what goes wrong (over-ceremony, awkward tag naming, dep on swift-property-primitives for no gain).

- [ ] **[research]** swift-threads/Research/thread-dispatch-taxonomy.md: Run the minimal experiment for Option A (conform `Kernel.Thread.Executor.Sharded` to `TaskExecutor`). If verified, implement the conformance and tighten swift-executors' scope statement to canonical "types that ARE Swift executors." The research doc is drafted but recommendation is PENDING; finishing it closes the taxonomy loop.
