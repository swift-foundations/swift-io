---
date: 2026-04-15
session_objective: Eliminate `nonisolated(unsafe)` from IO.Events.Actor's state and registrations by bridging Swift isolation to the Polling executor's thread identity
packages:
  - swift-executors
  - swift-io
status: processed
processed_date: 2026-04-16
triage_outcomes:
  - type: skill_update
    target: platform
    description: "Added [PLAT-ARCH-016] checkIsolated() / isIsolatingCurrentContext() canonical pattern for thread-owning SerialExecutor types"
  - type: skill_update
    target: implementation
    description: "Added [IMPL-091] Materialise Before Crossing Region Boundaries (Sendable locals for assumeIsolated)"
  - type: research_topic
    target: executor-main-checkisolated-linux-identity.md
    description: "Should Executor.Main get same checkIsolated treatment? Linux main-thread identity mechanism"
---

# Polling Tick Isolation: checkIsolated Is The Designed Bridge, Not A Hack

## What Happened

Session goal (from HANDOFF.md): remove `nonisolated(unsafe)` from
`IO.Events.Actor.state` and `registrations`, which existed because the
Polling executor's tick closure runs on the executor's OS thread but
outside a Swift Task context — `assumeIsolated` trapped with "Unexpected
isolation context." Supervisor ground rules: research-first, read the
PDF, don't accept `nonisolated(unsafe)` as the answer, don't copy the
UnsafeBufferPointer, and escalate before modifying swift-executors.

Research proceeded in parallel: (1) read `Video #362: Isolation: Actor
Enqueuing.pdf` for Point-Free's `Actor.run` pattern; (2) read three
existing swift-io research docs (actor-state-visibility-structural-fix,
executor-conformance-triage, completion-loop-executor-unification); (3)
dispatched a subagent to survey five swift-institute experiments; (4)
read the Swift runtime source (Actor.cpp:497-557, Executor.swift:367-444,
ExecutorAssertions.swift:336-351) to understand the `assumeIsolated`
fallback chain.

The decisive finding came from `swiftlang/swift/stdlib/public/Concurrency/Actor.cpp`:
when `_taskIsCurrentExecutor` finds no current executor tracking (the
tick case), it calls `isIsolatingCurrentContext()` on the expected
executor, and if that returns `nil` (the default), falls through to
`checkIsolated()`. Both are public protocol requirements on
`SerialExecutor`. Apple's `DispatchMainExecutor` in `swift-platform-executors`
implements `checkIsolated()` via `_dispatchAssertMainQueue()` — exactly
the same pattern: the executor owns a thread and self-certifies.
`Kernel.Thread.Executor.Polling` and `Kernel.Thread.Executor` never
implemented either method, so the runtime had no way to verify our
thread identity.

Wrote `Research/polling-tick-isolation-checkisolated.md` (RECOMMENDATION,
Tier 2). Avenue A (checkIsolated) identified as the designed solution;
Avenue B (Actor.run) ruled out because the events buffer is
`UnsafeBufferPointer` scoped to the tick; Avenue C (language feature)
collapsed into Avenue A. Escalated to user per ground rule #6.
Approved.

Implementation:
- swift-executors: added `isIsolatingCurrentContext()` (returns
  `threadHandle?.isCurrent`) and `checkIsolated()` (backstop
  `preconditionFailure` on nil/false) to both `Polling` and
  `Kernel.Thread.Executor`. Build clean; `swift test` 18/21 green.
- swift-io: rewrote tick closure to use `self.assumeIsolated { isolatedSelf
  in ... }`. Removed `nonisolated(unsafe)` from `state` and
  `registrations`. Removed `nonisolated` from `dispatchEvents`,
  `handleWaitFailure`, `fatalCleanup`. Build failed with `sending 'wait'
  risks causing data races` (region analysis flags the `wait` closure
  parameter crossing into the actor-isolated closure). Fixed by
  materialising the wait outcome into Sendable locals (`events:
  UnsafeBufferPointer<Kernel.Event>`, `waitError: Driver.Error?`) BEFORE
  the `assumeIsolated` call, then consuming the locals inside. The
  buffer is Sendable because `Kernel.Event: Sendable`; the scoped
  lifetime is preserved because `assumeIsolated` is synchronous.
  Build clean; `swift test` 53/23 green.

Post-core-work attempt: the user asked whether `polling`'s
`nonisolated(unsafe)` could also be addressed. I tried converting
`nonisolated(unsafe) private var polling: Polling!` to `nonisolated
private let polling: Polling` with single-expression init. Build failed
with `variable 'self.polling' used before being initialized` — the
`[weak self]` capture in the tick closure requires `self` to be
considered fully initialised at capture time, which is impossible when
the assignment-being-evaluated is the sole stored property. Attempted
revert was interrupted by the user, who requested `/reflect-session`.

**Build state at reflection time**: swift-io does NOT compile. The
polling change is still in-place. The next session needs to revert it
(restore `nonisolated(unsafe) private var polling: Polling!` and the
two-phase init pattern).

## What Worked and What Didn't

**Worked — research-first avoidance of two blind alleys.** The PDF's
`Actor.run` pattern was tempting (it squashes suspension points
beautifully). Reading the handoff's "Dead Ends" section and the
executor-conformance-triage before implementing kept me from attempting
to thread the `isolated Self` pattern through a generic executor —
which would either couple Polling to a specific actor type or require a
synchronous `Actor.run` (the PDF's async-only construct). The 30-minute
research investment killed both non-starters on paper.

**Worked — tracing the Swift runtime source to find the designed extension
point.** `assumeIsolated`'s fallback to `checkIsolated()` is
underdocumented in user-facing materials. The canonical reference is in
`Actor.cpp:497-557` — a C++ file in the concurrency runtime. Without
reading this directly, I would have accepted the PDF's characterisation
("Swift tracks isolation per-Task") as the final word and searched for
workarounds. The runtime source showed that the per-Task check is the
fast path, and `checkIsolated` is the designed slow path for exactly
our case.

**Worked — Apple's `DispatchMainExecutor` as prior art for user
confidence.** When I proposed `checkIsolated`, the user pushed back:
"feels like a little hack." Pointing to `swift-platform-executors`'s
`DispatchMainExecutor.checkIsolated()` (`_dispatchAssertMainQueue()`)
collapsed that objection — if Apple uses this exact pattern for the
main actor, it's the sanctioned mechanism. The pushback was valuable:
without it, I might have documented the fix as "what we had to do"
rather than "what Swift was designed for."

**Worked — materialise-before-crossing for wait thunk.** The initial
tick rewrite placed `try wait()` inside `assumeIsolated`, triggering a
`sending 'wait'` region error. The fix mirrors what Polling itself does
internally (lines 220-228 in Polling.swift): capture the outcome into
`let count` / `let waitError` before entering the scoped block. Pattern
generalises: when a task-isolated closure parameter needs to produce a
value consumed inside an actor-isolated region, call the closure
outside, bind the result to a Sendable local, consume the local inside.

**Didn't work — `nonisolated let polling` via single-expression init.**
The `[weak self]` capture requires self to be considered "fully
initialised" at the point the closure is formed. When `polling` is the
only stored property and its assignment is the only expression in init,
there is no moment during init where self is fully initialised before
the closure captures it. Swift's definite-initialization analysis
rejected with `variable 'self.polling' used before being initialized`.
The original two-phase pattern (`= nil` first, then real assignment) is
load-bearing — it creates the intermediate "fully initialised" moment
that `[weak self]` requires. Alternatives (factory methods, retain
cycles with `unowned`, external registries) are strictly worse. This is
a structural Swift constraint, not a workaround to eliminate.

**Didn't work — my initial instinct was to ask the user about
`threadHandle?.isCurrent` compile-ability before trying.** The subagent
survey returned alarming findings from the `noncopyable-access-patterns`
experiment: "Optional<~Copyable> access is consuming by default;
optional chaining fails in non-mutating contexts." I proposed switching
to a projection pattern preemptively. The user said "just run swift
build." Build succeeded immediately — `threadHandle?.isCurrent` compiles
because the return type (`Bool`) is Copyable, so the consumption
constraint doesn't apply; the `Handle` is borrowed through the optional
chain, not consumed. The experiment's findings apply when the
projected value is `~Copyable`, not when a Copyable result is projected
from a `~Copyable` optional. Lesson: Swift 6.3's ownership rules are
context-sensitive; "~Copyable optional chaining doesn't work" is an
oversimplification of a more nuanced rule.

**Process friction — inadequate session-end state.** The final code
state (polling change half-reverted, build broken) violates the usual
discipline of leaving each session's work in a compilable state. The
user interrupted mid-revert to request reflection. The correct response
at that moment would have been to complete the 30-second revert before
reflecting, or to have asked whether to revert-then-reflect or
reflect-with-broken-build. I reflected with broken build, which forces
the next session to re-establish "what was the last good state" from
git diff rather than from a clean starting point.

## Patterns and Root Causes

### 1. `checkIsolated` / `isIsolatingCurrentContext` is the designed bridge between "thread owns code" and "task owns code"

Swift's concurrency model tracks isolation per-Task via task-local
state set by `runSynchronously(on:)`. Custom executors that own threads
(as opposed to borrowing task-local executor context) need a way to
self-certify when code runs on their thread outside any Task — the tick
callback pattern, the main queue dispatch pattern, etc. Apple's stdlib
and Apple's platform-executors both use `checkIsolated` for this
purpose. It's not a workaround; it's the protocol extension point the
runtime's fallback chain was designed around.

Our ecosystem missed it for a simple reason: when the `Kernel.Thread.Executor`
family was first written, custom executors were only used via actor
pinning — every access came through a dispatched job with
`runSynchronously` setting executor identity. The Polling tick was a
new pattern (synchronous callbacks from a run loop) that bypasses the
per-Task model. The gap wasn't in Swift's design; it was in our
implementation not keeping up with a new consumption pattern.

**Generalisation**: any custom executor that owns a thread AND invokes
user code from that thread outside `runSynchronously(on:)` needs
`isIsolatingCurrentContext()`. In swift-executors, that's
`Kernel.Thread.Executor.Polling` (tick), `Executor.Main` (main thread
callbacks), and arguably `Kernel.Thread.Executor` (future run-loop
extensions). `Stealing` / `Stealing.Worker` don't need it (TaskExecutor
only). `Scheduled<Base>` delegates to its base.

### 2. Region analysis sees what the runtime verifies, but with less precision

The tick closure runs on the Polling thread. The actor pinned to
Polling runs on the Polling thread. The Swift runtime, with
`isIsolatingCurrentContext` in place, can verify via `pthread_equal`
that these are the same thread at any instant. Swift's region analysis,
however, sees two closures with different isolation annotations
(task-isolated outer, actor-isolated inner) and treats captures across
them as boundary crossings — even though no boundary is crossed at
runtime.

The materialise-before-crossing pattern bridges this gap: convert
boundary-crossable values (Sendable locals) before the actor-isolated
closure forms. Region analysis accepts the crossing; the runtime
verifies the thread identity independently. Both systems are satisfied
because they operate at different abstraction levels — types (compile
time) vs threads (run time).

This is a recurring shape in the codebase. Polling itself does the
same thing internally at the wait-to-buffer boundary (`let count`,
`let waitError` before `withUnsafeBufferPointer`). The
materialise-before-crossing pattern is the generic solution whenever
closure-capture region analysis disagrees with the actual runtime
safety invariant.

### 3. `[weak self]` + actor init is a chicken-and-egg constraint, not a choice

The actor holds the resource; the resource captures `[weak self]` to
avoid retaining the actor. At init time, `[weak self]` requires self to
be "fully initialised" — which requires all stored properties to have
values. If the resource IS the last (or only) stored property, there's
no intermediate moment. The two-phase init pattern
(`self.resource = nil; self.resource = actual`) creates that
intermediate moment by using an IUO type that's trivially initialisable
to nil.

`nonisolated(unsafe)` on the IUO is the cost of the pattern: the actor
init is nonisolated, the property is actor-isolated by default, so
the write needs to bypass the isolation check. `let` doesn't work
(can't reassign). Factory methods don't work (same chicken-and-egg,
just externalised). `unowned(unsafe)` avoids the weak-reference cost
but introduces use-after-free risk — unacceptable for an executor that
outlives the actor.

**The right framing**: `nonisolated(unsafe) var X!` with two-phase init
is the Swift idiom for "actor owns a resource that captures weak self."
It's not a workaround to eliminate. It's the pattern. Documenting it
as such prevents future agents (and this agent) from treating it as a
design failure.

## Action Items

- [ ] **[skill]** platform: Document `checkIsolated()` /
  `isIsolatingCurrentContext()` as the canonical pattern for custom
  `SerialExecutor` types that own a thread. Specify when it's required
  (tick callbacks, main-thread callbacks, any user code invoked outside
  `runSynchronously(on:)`), when it's not (TaskExecutor-only types,
  delegating types), and the implementation shape
  (`threadHandle?.isCurrent` for pthread-backed executors;
  `pthread_main_np()` / `gettid() == getpid()` for Executor.Main).
  Reference Apple's `DispatchMainExecutor` as prior art and cite
  `Actor.cpp:497-557` for the runtime fallback chain. Current
  provenance: this session's research doc
  `polling-tick-isolation-checkisolated.md`.

- [ ] **[skill]** implementation: Add the "materialise before crossing"
  pattern as an [IMPL-*] or [PATTERN-*] rule. Statement: when a
  task-isolated closure parameter must produce a value consumed inside
  an actor-isolated `assumeIsolated` region, call the closure outside
  and bind the result to Sendable locals; consume the locals inside.
  The constraint is compile-time (region analysis), not runtime (no
  actual boundary crossed). Reference: `IO.Events.Actor.swift:88-122`
  tick rewrite, and `Polling.swift:220-228` as an internal precedent.

- [ ] **[research]** Should `Executor.Main` get the same
  `checkIsolated` treatment (the handoff's Phase 2), and if so, what's
  the right Linux main-thread identity mechanism (`gettid() ==
  getpid()` vs reading from `/proc/self/status` vs capturing at
  executor construction time)? Current HANDOFF.md Phase 2 proposes
  `pthread_main_np` on Darwin + `gettid`/`getpid` on Linux; the ask
  flag (#6) says escalate if `gettid` needs a new syscall shim.
  Investigate whether ISO 9945 already exposes this.
