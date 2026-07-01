---
date: 2026-04-07
session_objective: Get io-bench green after Phase 3; investigate release-mode shutdown test failures
packages:
  - swift-io
  - swift-file-system
status: processed
processed_date: 2026-04-16
triage_outcomes:
  - type: skill_update
    target: handoff
    description: "Added [HANDOFF-013] Prior Research Check for Branching Investigations"
  - type: skill_update
    target: issue-investigation
    description: "Added [ISSUE-023] Debug-Prints-First Ladder for Release-Mode-Only Bugs"
  - type: no_action
    description: "[research] Fix A structural soundness — superseded by 2026-04-08 DEFERRED audit (actor-state-visibility finding parked with full context)"
---

# Actor state via inline-fallback: release-mode visibility bug, fresh-eyes delegation, handoff proliferation

## What Happened

Session started after Phase 3 was committed (integrated `IO.Event.Loop`,
actor-owned driver, request queue eliminated). Main goal was to
unblock io-bench, which had been sitting unrun since April 3.

Concrete progress:

- **io-bench unblocked.** Cascading `MemberImportVisibility` errors
  fanned out from swift-file-system to swift-tests to io-bench. Added
  `public import IO_Executor` to 15 files in swift-file-system, 3 in
  swift-tests, plus `import Kernel` / `IO_Events` to 5 files in
  io-bench itself. io-bench now builds and runs in release with the
  required `-Xswiftc -Xllvm -Xswiftc -sil-disable-pass=CopyPropagation`
  flag (saved to memory).

- **Benchmark comparison against nio-bench.** Geometric mean across
  the `Benchmark.*` namespace: **0.98x** (essentially at parity with
  SwiftNIO). swift-io wins on small-message socket latency (7.5x echo
  round-trip), warm shutdown (1.8x), high-concurrency fast ops (1.4x).
  NIO wins on bulk 1MB channel throughput (2.3x) and per-dispatch
  overhead (~1.3x). The `Test.Performance.*` namespace is duplicated
  dead test code on both sides — compare only `Benchmark.*`.

- **Post-Phase-3 cleanup.** Dropped redundant `Ownership.Mutable`
  wrapper from Loop fields (the Loop is already a class, the wrapper
  was one layer of indirection too many). Dropped all
  `nonisolated(unsafe)` annotations — they were redundant with
  `@unchecked Sendable` on the class. Deleted `IO.Closure` and
  `IO.Closure.Error` types which had zero users. 379/379 debug tests
  pass.

- **Three tier-0 architectural debates, none resolved.** Modularization
  target (5 modules: IO Core, IO Blocking, IO Events, IO Completions,
  IO). Typed throws shape for `IO.run.blocking { try op() }`. Fate of
  the `IO.Lane` wrapper. Spent ~4 iterations circling these before
  the user pulled me up and asked for fresh eyes. Delegated public-API
  review to a subagent via branching handoff; subagent caught that I
  had written `Research/public-api-spec.md` without noticing the
  pre-existing `Research/tier-0-consumer-api-review.md` from the day
  before, which contradicted my spec on several points. Deleted my
  spec.

- **Release-mode shutdown test failures — confirmed root cause, no
  structural fix yet.** Three tests in
  `IO.Event.Selector.Shutdown.Tests` fail reliably in release mode
  (debug mode 379/379). Debug prints in `Runtime.shutdown()` and
  `Runtime.register()` on release build produced:

  ```
  DEBUG: shutdown called, state = running
  DEBUG: shutdown set state = .shuttingDown
  DEBUG: register called, state = running   ← stale read
  ```

  The Runtime actor's `state` field is written during
  `Runtime.shutdown()` on the executor thread. The subsequent
  `Runtime.register()` call, running via `Loop.enqueue`'s inline
  fallback on the test thread after the executor has joined, reads
  `state` as `.running` — the write never became visible across
  threads. This is release-mode only.

  Attempted tactical fix: moved the `dup` from Selector.register into
  Runtime.register, on the theory that the admission check needed to
  run before the dup even gets a chance to fail. It didn't work — the
  admission check still reads stale state. Committed as checkpoint
  anyway (`2a2a617b`) because the dup-on-actor-side change is probably
  correct regardless of what fixes the visibility issue.

  Delegated the structural fix to a fresh agent via
  `HANDOFF-actor-state-visibility-fix.md` with an explicit brief:
  type-system-enforced, refactor-proof, no `nonisolated(unsafe)`, no
  existentials. Parent will review the design proposal and execute.

- **SIGSEGV in release mode: observed, not diagnosed.** The test run
  also crashes with signal 11 somewhere. 184 tests in-flight when the
  capture ended; can't pinpoint the culprit without a live sample.
  Likely same root cause as the stale state read, but unconfirmed.

Handoff files written this session: `HANDOFF-io-bench-recompile.md`
(now obsolete), `HANDOFF-public-api-review.md` (fresh-eyes review
completed with findings), `HANDOFF-actor-state-visibility-fix.md`
(active investigation). `HANDOFF.md` updated to reflect end-of-session
state.

## What Worked and What Didn't

**Worked:**

- **Debug prints over reasoning for release-mode visibility bugs.** I
  spent ~20 minutes source-reading and building theories about why
  the admission check wasn't catching shutdown before I added the
  three `print()` statements that instantly revealed the actual
  state-sequence. The prints were the minimum-effort, maximum-signal
  diagnostic. I should reach for prints sooner when debug/release
  diverge.

- **Fresh-eyes delegation via branching handoff.** The subagent caught
  the contradicting research doc in one grep and pushed back on my
  Option 1a reasoning with a specific argument grounded in both
  [API-ERR-001]'s literal text and the known compiler bug at
  `IO.Run.swift:50-53`. Both were things I'd missed. The branching
  handoff pattern is a good circuit-breaker for "we're going in
  circles."

- **Benchmark-as-regression-signal.** Comparing the latest io-bench
  .benchmark data against the April 3 baseline revealed Phase 3's
  impact concretely: 49 improvements averaging 30–70%, 7 regressions
  (3 of them stubbed tests, 4 real but small, 1 dramatic). This made
  the "did Phase 3 help?" question answerable without speculation.

- **Committing checkpoint work even when it doesn't solve the problem.**
  The dup-inside-actor change at `2a2a617b` is a checkpoint that
  documents a partial fix and the observed root cause in the commit
  message. Future me (or the investigation agent) can read the commit
  and see exactly what was tried and what the diagnostic output said.

**Didn't work:**

- **Writing a public-API spec without reading existing research docs.**
  I authored `Research/public-api-spec.md` from scratch without `ls
  Research/` first. The pre-existing `tier-0-consumer-api-review.md`
  had already solved half the questions I was posing. The subagent
  caught this in seconds. Direct waste: ~30 minutes of writing + the
  downstream confusion of having two contradicting specs live at once.

- **Going in architectural circles.** The typed-throws question cycled
  through four options (Work envelope, any Error, generic IO.Error,
  rename-and-move) without converging, because I was operating under
  an assumption about `[API-ERR-001]` that was stricter than the
  skill's literal text. The user's intervention ("no existentials,
  period — and let's think higher-level about modularization") broke
  the cycle. Without that intervention I would have kept churning.

- **My first release-mode theory (lost wakeup race).** I walked through
  a race condition between `drainJobs()` returning and `poll()` starting
  and confidently called it a bug. It isn't — the kernel buffers
  `EVFILT_USER` / `eventfd` signals until consumed, closing the
  window. I had to walk it back in the next message after actually
  reading swift-kernel's wakeup implementation. Speculating before
  verifying wasted user trust.

- **Atomic-based fix instinct.** My first reflex when the release-mode
  bug was confirmed was to reach for `Atomic<UInt8>` on the state
  field. The user correctly pushed back: atomics would paper over the
  symptom, but we don't understand WHY the actor model isn't
  providing the cross-thread visibility we expected. The atomic would
  make the next field's bug harder to find. Band-aid, not fix.

## Patterns and Root Causes

**1. Inline-executor fallback is a supersession signal for Fix A.**

`Kernel.Thread.Executor.enqueue()` has the same "if !isRunning, run
the job synchronously on the caller" pattern. Memory note
`feedback_test_hang_timeouts.md` calls this "Fix A" and asserts it's
"the canonical deadlock prevention, enforced at the executor level,
covers all actors automatically."

The claim is testable in two pieces: (a) does it prevent post-shutdown
hangs? Yes. (b) does it preserve actor-isolation semantics for state
reads across threads? **This session's evidence says no, at least in
release mode with swift-io's Runtime actor.**

The memory note may need to be updated to "Fix A prevents hangs but
has a latent memory-visibility issue when the actor has stored state
that must be read post-shutdown via the inline path." But I'm
cautious about that claim because I haven't isolated the root cause
— it could be specific to swift-io's pattern, to release-mode compiler
behavior, or to a genuine flaw in Fix A itself. The branching
investigation will determine which. For now, Fix A is not as safe as
the note claims, and this reflection is the tag on that uncertainty.

**2. "Search before you write" is a discipline I keep failing.**

This is the second or third session where I've written a new design
doc only to discover a prior doc in the same folder already addressed
the topic. The retrospective pattern is clear: before writing any
file in `Research/`, grep for the topic keywords first. I can get
away with skipping this when the code is fresh and there's no prior
research, but swift-io has 7+ research docs and the likelihood of
overlap is high.

The subagent in this session demonstrated the right workflow: read
the handoff brief, read the skills it referenced, THEN grep Research/
for relevant prior work, THEN form an opinion. I skipped steps 2 and
3 when writing my spec, and it cost me.

**3. Architectural debate without executable code loops.**

The typed-throws discussion iterated four times over ~30 minutes of
conversation. Each iteration refined the problem statement slightly
but didn't converge on a decision. The pattern was: I propose an
option, user pushes back on a constraint I missed, I propose
another, repeat. This wasn't productive — we were refining my
understanding of the constraints, not the solution.

The breakthrough was the user's meta-question: "what's the
modularization you actually want?" That reframed the problem from
"pick one of four type signatures" to "what's the shape of the
module boundary where these signatures live?" Once the boundary was
agreed, the type signatures became obvious (or at least constrained
enough to be tractable).

**The lesson**: when a discussion is cycling through options at
the same level of detail without converging, zoom out. Ask the
user (or ask yourself) "what constraint am I missing that would
eliminate most of these options?" This is Derby & Larsen 2006's
"remove options, don't add them" advice.

**4. Release-mode-only bugs have a specific diagnostic ladder.**

Debug mode passes, release mode fails → the difference is compiler
optimization OR memory ordering. Neither is visible from source
reading. The diagnostic ladder is:

1. **Add print statements** to the suspect path. Verify what's
   actually executing and what values are being read/written. Cost:
   90 seconds of editing + rebuild. Signal: definitive — you see the
   ground truth.
2. **Write a minimal standalone experiment.** If the prints confirm
   the anomaly, extract the suspect pattern into a standalone Swift
   package and see if it reproduces. Cost: ~30 minutes. Signal:
   confirms the bug is in Swift/compiler, not our code.
3. **Read the generated SIL** for the suspect function. Cost: high,
   requires reading intermediate representation. Signal: definitive
   on what the compiler is doing.

I skipped step 1 and went to step 3 (reading source and imagining
what the compiler might do). That was backwards. Start with prints.

## Action Items

- [ ] **[skill]** handoff: add a rule that branching investigations on
  architectural questions MUST grep the target repo's `Research/` for
  prior related docs before writing findings. This session the
  subagent caught my missed `tier-0-consumer-api-review.md`; I should
  make that discipline explicit in the handoff skill so the subagent
  (and future me) doesn't skip it.

- [ ] **[skill]** issue-investigation: add the "debug-prints-first"
  ladder for release-mode-only bugs. When debug passes and release
  fails, the first tool should be `print()` to verify what the code
  actually does, not source-reading. This session's bug was diagnosed
  in 90 seconds once I stopped theorizing and added three prints.

- [ ] **[research]** Is `Kernel.Thread.Executor`'s Fix A (inline
  execution on dead executor) structurally sound for actors with
  stored state that must be visible post-shutdown? The answer may be
  "yes, but only on strongly-ordered memory models" or "no, the
  pattern was always broken for this case." If the
  `HANDOFF-actor-state-visibility-fix.md` investigation reaches a
  definitive answer, promote it to research and update the
  `feedback_test_hang_timeouts.md` memory note.
