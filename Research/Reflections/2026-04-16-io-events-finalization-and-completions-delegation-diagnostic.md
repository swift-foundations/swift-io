---
date: 2026-04-16
session_objective: Finalize the IO.Events simplification arc; diagnose IO.Completions following the same pattern
packages:
  - swift-io
  - swift-sockets
  - swift-kernel
status: processed
processed_date: 2026-04-24
triage_outcomes: see reflections-processing run 2026-04-24
---

# IO.Events Finalization and IO.Completions Delegation Diagnostic

## What Happened

Two-arc session. The first arc closed out IO.Events's simplification;
the second diagnosed IO.Completions against the same template and
pivoted the planned refactor from a local collapse (Option B) to a
delegation-first rewrite (Option C) after the user recognized that
`Kernel.Completion` already delivers the platform unification
`IO.Completion.Driver` was wrapping.

### Arc 1 — IO.Events simplification (8 commits)

- `4695689f` IO: factory cleanup (`create()` → throwing `init()`) across
  `IO.Events` and `IO.Completions`. Collapsed `SharedEvents` actor
  ceremony into a static-let `Result` cache. Added `IO.Completions.shared()`
  + no-arg `IO.completions()`. `IO.default()` now routes through
  `.shared()`.
- `ca0ad407` Collapsed `IO.Events` struct wrapper → public
  `IO.Event.Actor` via namespace adoption ([API-NAME-004a]).
- `83829f47` Added `@unsafe` to `IO.Event.Actor.Handle` per
  [MEM-SAFE-024] Category A.
- `73884821` Audit cleanups: moved `unownedExecutor` to extension
  ([API-IMPL-008]); element-wise iteration in tick
  (`for unsafe event in events`); extracted `registerWithDriver` helper
  to fold three-domain error translation in `ensureRegistered`;
  PATTERN-016 structured comment on the tick's region-transfer
  contortion.
- `923c0cad` Renamed compound internal methods
  (`dispatchEvents` → `dispatch`, `ensureRegistered` → `register`,
  `awaitReadiness` → `wait(for:interest:)`, `fatalCleanup` → `cleanup`);
  inlined `handleWaitFailure` and `registerWithDriver`; extracted
  `Registration.Senders` with composable primitives (`append(_:for:)`,
  `drain(event:for:)`, `closeAll()`).
- `f0eb9908` Exposed `maxEventsPerPoll: Int` as direct init parameter
  and added source-injection init
  (`init(source: consuming Kernel.Event.Source, maxEventsPerPoll: Int = 256)`).
  Extracted `makeTick(for:)` as `private static` on an `IO.Event.Actor`
  extension, avoiding both `fileprivate` and a Polling-extension init
  (both considered, both rejected).
- Tests (swift-io + swift-sockets) updated across every rename.
- IO Events README rewritten twice to track the architecture.

Audit landed clean: 3 LOW findings per skill (code-surface,
implementation, memory-safety, modularization), all either RESOLVED
in-session or reclassified FALSE_POSITIVE (then later resolved anyway
on user pushback — see Pattern 1).

### Arc 2 — IO.Completions diagnostic

- Wrote `HANDOFF-io-completions-simplification.md` with Option A
  (full parallel including Loop collapse) vs Option B (struct-collapse
  only). Recommended B.
- User asked: "why is IO.Completions currently more complex than
  Blocking and Events?" Dispatched Explore agent; got a per-type
  classification across 24 types (domain-inherent vs paradigm-specific
  vs historical vs accidental).
- User observed: "Kernel Completion already provides the IOCP/io_uring
  unification. IO Completions should not at all be concerned with the
  difference." Dispatched a second Explore agent to verify; confirmed
  `Kernel.Completion` delivers the same unification pattern as
  `Kernel.Event` (L1 `Driver` witness + L3 `platform()` factory), and
  that `IO.Completion.Driver` is a largely-redundant second witness
  layer on top of it.
- Upgraded handoff from Option B → Option C (delegation-first): drop
  `IO.Completion.Driver`/`Handle`/`Capabilities`/`+Platform`,
  namespace-adopt `IO.Completion = Kernel.Completion`, typealias
  `Kind`/`Flags` to the kernel equivalents, then apply the struct +
  Loop collapses on top. Expected: 28 files → ~10-12.
- Wrote `Sources/IO Completions/README.md` (commit `7265c9ae`) as
  diagnostic artifact mirroring the IO Events README. Per-file
  inventory + honest split (domain-inherent / duplicated / accidental).
  Section 10 sketches the target shape.
- User began Phase 1 of the refactor (file edits visible in
  `IO+Completions.swift`, `IO.Completions.swift`, `README.md`).

### Process tensions resolved by user pushback

- **FALSE_POSITIVE on compound internals** → RESOLVED. I classified
  `dispatchEvents`/`ensureRegistered`/`awaitReadiness` etc. as
  FALSE_POSITIVE citing `feedback_compound_package_scope`. User said
  "I see a lot of violations of /code-surface, in particular re
  compound identifiers." Reclassified + renamed.
- **`fileprivate` for state/dispatch/cleanup** → rejected. I proposed
  widening to fileprivate when moving the tick helper to a Polling
  extension. User: "avoid fileprivate. do better." Redesigned to
  `private static makeTick` on an `IO.Event.Actor` extension
  (same-type-same-file private access).
- **Options struct for `maxEventsPerPoll`** → rejected. I proposed
  `IO.Event.Actor.Options` wrapping a single Int. User: "the init
  should pass the Int right so you can do .init(maxnumber: 257)."
  Collapsed to direct parameter.
- **Polling extension for `buildPolling`** → partially rejected. User
  suggested the helper live on `Kernel.Thread.Executor.Polling`. I
  tried that path, hit the fileprivate requirement, escaped via static
  on Actor extension. Ended up a local optimum rather than the
  Polling-extension global.

## What Worked and What Didn't

### Worked

- **Progressive, small commits** per logical change — each commit
  represents a cohesive refactor step and can be reverted independently.
- **Writing the Completions README as a diagnostic artifact**.
  Articulating each type's purpose forced clarity; clarity exposed the
  duplication; the user then adopted the README as the refactor target.
  The diagnostic doc was the pivot point from Option B to Option C.
- **Explore agent for systematic classification**. The 24-type bucket
  analysis was mechanical work the agent did well — I would have been
  less thorough if I'd done it inline.
- **User pushback loop was tighter than my initial analyses**. Three
  times this session (compound renames, fileprivate, Options struct),
  my first proposal was a local optimum; the user's nudge found the
  global optimum at the same effort.

### Didn't work

- **FALSE_POSITIVE classification on internal compound identifiers
  was too generous**. I cited `feedback_compound_package_scope` as
  finality. The memory permits compound at internal scope but doesn't
  recommend it. I conflated permission with preference.
- **First tick-helper proposal (`Self.buildPolling` inside the actor
  body)** missed [API-IMPL-008] — methods belong in extensions. Only
  corrected when user questioned the shape.
- **Initial IO.Completions analysis missed the Kernel.Completion
  duplication**. I classified `IO.Completion.Driver` as
  "paradigm-specific policy layering" — legitimate L3 wrapping of L1.
  It's actually mostly a redundant second witness layer on top of
  `Kernel.Completion.Driver`. The user's pointed question was the
  reveal.
- **Redundant iteration on the Polling-extension path**. I proposed a
  `private extension Kernel.Thread.Executor.Polling` init, hit
  fileprivate, got told to avoid fileprivate, then iterated back to a
  static on an Actor extension. The cleaner design was reachable
  without the Polling-extension detour.

## Patterns and Root Causes

### Pattern 1 — Permission is not preference

Skill memories document what's *permitted* to prevent regressions.
They don't relieve you from better design.
`feedback_compound_package_scope` permits compound identifiers at
internal/package scope (to avoid churn on pragmatic renames). I cited
it as finality for a FALSE_POSITIVE classification. User corrected: the
rule tells you what you can get away with; the preferred form remains
nested/single-concept even at internal scope. Default going forward:
check whether a cleaner form exists before citing permission as
sufficient.

This generalizes across all "permission memories" — each one answers
"can I do X?" but not "should I?" The skill-level guidance is what
matters for the "should"; the memory is a permission bracket around
edge cases.

### Pattern 2 — Template-driven simplification across a tier

The three IO strategies form a tier with a minimal reference
(`IO.Blocking`: struct wrapping a Sharded executor, no Loop, no
wrappers). `IO.Events` was simplified *toward* that reference across
this session + prior work. `IO.Completions` remained farther from it.
The simplification workflow:

1. Identify the minimal template in the tier.
2. For each divergent strategy, identify what each divergence buys.
3. Classify: domain-intrinsic / paradigm-specific / historical /
   accidental.
4. Collapse everything except domain-intrinsic.

This is reusable across any tier of parallel strategies (Kernel.Event
backends, Kernel.Completion backends, future IO strategies, sockets
listener types, etc.). The template-and-classify discipline separates
"must be different" from "was different for reasons that no longer
apply."

### Pattern 3 — L1 unification + L3 thin consumer is the kernel-layer shape

Both `Kernel.Event` and `Kernel.Completion` implement the same
architecture:

- L1 witness struct (`Kernel.Event.Driver`, `Kernel.Completion.Driver`)
  — platform-agnostic operation vocabulary.
- L1 resource struct (`Kernel.Event.Source`, `Kernel.Completion`) —
  `~Copyable` wrapper holding the driver.
- L3 platform factory (`Kernel.Event.Source.platform()`,
  `Kernel.Completion.platform()`) — the single file where `#if os()`
  lives.
- L3 consumer (`IO.Event.Actor`) — consumes the L1 resource directly.
  Zero platform code.

`IO.Event.Actor` got this right. `IO.Completions` built a second
witness layer (`IO.Completion.Driver`) on top of the L1 witness —
mostly delegating, occasionally adding policy (blocking-poll
semantics). **Recognizing this pattern lets you spot the duplication
immediately** on any future strategy. The question to ask:
*does this L3 witness add genuine policy the L1 cannot express, or is
it re-wrapping the platform dispatch the L1 already did?*

### Pattern 4 — Write the target-state design doc as diagnostic

The IO Completions README was written before the refactor. The act of
writing forced me to articulate each type's purpose. The articulation
made the duplication obvious. The user then adopted the README as the
refactor target (upgrading Option B to Option C).

This is a reusable workflow for large refactors:
1. Write the current-state design doc honestly (per-file inventory).
2. The writing exposes incoherence the code obscures.
3. Add a "target shape" section sketching the end state.
4. The handoff/plan references the doc; the new session reads the doc
   first.

The doc is cheaper than the refactor, reveals the refactor's scope
accurately, and doubles as the durable artifact after the refactor
lands (update in place).

### Pattern 5 — "Do better" from the user is a re-evaluation signal

Three times this session, my first proposal hit a local optimum and
the user's response was "do better" (or equivalent: "avoid fileprivate",
"use the Int directly", "that's wrong"). Each time the global optimum
was achievable with the same effort — not a tradeoff to a more
expensive solution, but a reframe. Pattern: when the user uses "do
better" or questions a proposal's default, re-evaluate from first
principles rather than patching within the current frame.

## Action Items

- [ ] **[skill]** code-surface: Add guidance to [API-NAME-002]
  explicitly noting that `feedback_compound_package_scope` permits
  compound identifiers at internal/package scope for pragmatic
  continuity (don't block PRs, don't mass-rename across large
  surfaces in one session), but the *preferred* style remains nested
  accessors or single-concept names even at internal scope.
  "Permitted ≠ recommended."

- [ ] **[blog]** Template-driven simplification across a tier. The
  IO.Blocking → IO.Events → IO.Completions arc is a clean case study
  for refactoring via reference templates. Identify the minimal
  template; classify each divergence as domain-intrinsic /
  paradigm-specific / historical / accidental; simplify toward the
  template.

- [ ] **[package]** swift-io: Add a `Research/` doc articulating the
  "L1 unification + L3 platform factory + L3 thin consumer" pattern
  explicitly, with `Kernel.Event` and `Kernel.Completion` as
  exemplars and `IO.Completion.Driver` as the anti-pattern that
  prompted the recognition. Name the pattern so future strategies
  (IOCP when it lands; any new kernel abstraction) don't rebuild it.

## Artifact cleanup

### Handoffs triaged

- `HANDOFF.md` (swift-sockets Phase 3 — unrelated work) — not touched
  this session; leave alone.
- `HANDOFF-io-completions-simplification.md` — Phase 1 appears to be
  in progress based on user edits to `IO+Completions.swift` /
  `IO.Completions.swift` / `README.md`. Phases 2, 3, 4 remain. Leave
  the file; its Phase-1 Next Steps are the active work.

### Audit findings

`Audits/audit.md` IO Events sections updated in-session: 3 LOW
code-surface (§1/§2 originally FALSE_POSITIVE, later RESOLVED per user
pushback; §3 RESOLVED); 3 LOW implementation (all RESOLVED); 1 MEDIUM
memory-safety (RESOLVED); 0 modularization findings. No stale statuses
from this session remain.
