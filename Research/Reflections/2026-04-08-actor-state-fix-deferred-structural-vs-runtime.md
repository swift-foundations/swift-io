---
date: 2026-04-08
session_objective: Execute the branching investigation from HANDOFF-actor-state-visibility-fix.md — verify the bug, design a structural fix, write the proposal
packages:
  - swift-io
status: processed
processed_date: 2026-04-16
triage_outcomes:
  - type: skill_update
    target: issue-investigation
    description: "Added [ISSUE-022] Ask Before Designing the Fix — surface aesthetic constraints before drafting proposals"
  - type: skill_update
    target: experiment-process
    description: "Added [EXP-011a] First clean signal IS the result"
  - type: research_topic
    target: sendable-heap-ref-lifetime-idiom.md
    description: "Canonical Swift idiom for 'reference cannot be used after scope ends' (class + Sendable)"
---

# Actor-state fix deferred: when the proposal is the right answer to the wrong question

## What Happened

This session was the branching investigation requested in
`HANDOFF-actor-state-visibility-fix.md`. Goal: verify the release-mode
shutdown bug, design a structural fix (no atomics, no
`nonisolated(unsafe)`, no existentials), write a design proposal.

Concrete output:

- **Bug confirmed.** `swift test -c release -Xswiftc -Xllvm -Xswiftc
  -sil-disable-pass=CopyPropagation --filter
  "shutdownGate|shutdownRejectsNew|typedErrorsLifecycle"` fails three
  tests with `Failure: Invalid descriptor` instead of
  `shutdownInProgress`. Debug mode passes 379/379. Reproduces every
  invocation.

- **Bug NOT reproduced in isolation.** Built
  `Experiments/actor-state-cross-thread-inline/` — five variants (V1
  baseline, V2 atomic mirror cross-validation, V3 1000-iteration loop,
  V4 swift-io two-call mimic, V5 side-effect after state check). 1003
  attempts in `-c release` with the same SIL flag. **Zero bug
  observations.** The minimal pattern (custom `SerialExecutor` + actor
  with `private var state` + `runSynchronously` inline-fallback +
  cross-thread state read) is insufficient to reproduce. Whatever
  miscompile is happening in swift-io needs more than the basic shape.

- **Slip-pattern proposal written.** ~32 KB at
  `Research/actor-state-visibility-structural-fix.md`. Option D:
  `~Copyable Sendable AdmissionSlip`, mintable only by `Loop.admit()`
  (synchronous atomic load), consumed by `Runtime.register(slip:
  consuming, ...)`. Compiler enforces single-use; admission state lives
  on the Loop with explicit `Atomic<UInt8>`; actor `state` field
  removed entirely. Comparison matrix vs handoff options A/B/C, full
  migration path, six open questions.

- **Findings appended to handoff.** Per the brief, ≤200 words
  summarizing what was found and where the writeup lives.

- **User pushed back on Option D.** "I actually think adding this
  Synchronization stuff is a regression, and is more likely pointing to
  more structural issues. I'd rather NOT add new checks, and instead
  fix the structure." Hard rejection of the slip pattern as a runtime
  workaround for a structural defect.

- **Another agent's review caught the structural defect.** `Scope` is
  `~Copyable, ~Escapable`, but its `selector: IO.Event.Selector` field
  is freely Sendable (struct holding two heap references — Loop class +
  Runtime actor). Callers can `let selector = scope.selector` and use
  it after `await scope.close()`. The `~Escapable` annotation is
  structurally lying. The slip pattern would have papered over a
  lifetime-modeling failure, not fixed it.

- **Three layers of structural fix sketched (L1/L2/L3).** L1: make
  `Scope.selector` internal, add scope-routed register/deregister
  methods. L2: L1 + make `Channel ~Escapable` (no longer Sendable),
  remove the actor `state` field entirely. L3: full Tier 0 redesign
  with closure-only scope. The other agent recommended L2; my
  recommendation aligned with verification first (audit Channel usage
  for Sendable dependencies before committing).

- **L1/L2/L3 also rejected.** All three "add registers etc." User
  preferred deletion-only: remove the `state` field, delete the three
  failing tests, accept a looser post-shutdown contract.

- **Work parked as audit DEFERRED.** Five findings written to
  `Research/audit.md` (Memory Safety: Cross-Thread Actor State
  Visibility — 2026-04-08). All DEFERRED pending structural fix
  decision. Committed as `81ba4388 Park actor-state visibility
  investigation as audit DEFERRED`. The note recommends revisiting
  when the Tier 0 API discussion is also ready to land — the two may
  benefit from being designed together.

## What Worked and What Didn't

**Worked:**

- **Empirical falsification of the diagnosis.** The minimal experiment
  set out to confirm "actor state is read stale via inline fallback."
  It returned a clean negative result. This was the most valuable
  output of the session because it changed the framing: the bug isn't
  a generic "memory ordering" issue you'd find in any Swift project,
  it's specific to swift-io's exact compiler-input shape. That shifted
  the design space from "use atomics harder" to "stop using
  actor-isolated state for admission at all."

- **Documenting what was tried, even when it failed.** The proposal
  includes the full negative-result section. Five variants, 1003
  attempts, exact code in the experiment directory. Future me (or a
  successor agent) can see exactly what was tested and rule those
  shapes out without re-running. Cost: ~5 minutes of writing.

- **The other agent's structural review.** The agent (a parallel
  session) read my proposal and the failing test and saw the
  `Scope.selector` lifetime leak in seconds. I had been so focused on
  "how do we make admission safe" that I missed the prior question:
  "why is admission ever happening on a thread that doesn't own the
  scope?" The structural review reframed the problem one level up.
  This is the same fresh-eyes-delegation pattern that worked in the
  prior session — the lesson keeps repeating.

- **The negative experiment as evidence in the proposal.** Including
  "I tried to reproduce and couldn't" in the design doc wasn't just
  honest — it was load-bearing. It justified Option D's framing
  ("don't trust the actor load under release optimization") and let
  the reader weight the proposal accordingly. If I had hidden the
  negative result, the proposal would have read as overconfident.

**Didn't work:**

- **My instinct toward the slip pattern was a runtime patch dressed
  as a structural fix.** I added `~Copyable AdmissionSlip` and called
  it "type-system enforcement." It IS type-system enforcement — but of
  the wrong invariant. The slip enforces "admission was checked before
  calling the actor method," which is a runtime check moved to a
  slightly earlier point. The structural defect is "the selector
  shouldn't be reachable post-scope-close." Different invariant.
  Different fix. The user's pushback was sharper than my proposal.

- **I conflated "type-system enforced" with "structural."** A
  `~Copyable` token is type-system enforced — single use, can't escape
  from the function it was passed into. But that's enforcing a
  procedural property (call A before B), not a structural property
  (X cannot exist after Y is destroyed). True structural fixes change
  what types can exist in what contexts. I knew the difference in the
  abstract; in the heat of writing the proposal I forgot to apply it.

- **Treating the negative repro as a problem instead of a finding.**
  When my experiment didn't reproduce the bug after V1, V2, V3, V4, V5
  I kept thinking "I need to make my experiment more like swift-io to
  trigger it." That was wasted effort — the experiment was already
  doing its job: telling me the bug is more specific than my mental
  model. I should have stopped at V3 (1000 iterations all clean) and
  recognized the negative result as the answer, not the obstacle.

- **Six "open questions" in the proposal.** Three of them (Q1
  ~Escapable, Q3 phantom Loop parameter, Q5 file Swift bug report)
  were design rabbit holes I wasn't going to resolve. They should have
  been omitted or collapsed into one note. The proposal was 32 KB; it
  could have been 20 KB if I'd been disciplined about scope.

- **Recommended option D in the Findings section.** The handoff asked
  for a design proposal. I recommended one. Then the user rejected it
  in less than a sentence ("I'd rather NOT add new checks"). The
  recommendation was confidently wrong because I never asked the user
  what shape of fix they wanted before designing one. A 30-second
  "before I write this — atomics OK?" question would have saved 90%
  of the proposal-writing time.

## Patterns and Root Causes

**1. The slip pattern as cargo-cult structural reasoning.**

I reached for `~Copyable` because it's the most-praised type-system
feature in this codebase. The reasoning was: "the parent values
type-system enforcement, ~Copyable is type-system enforcement,
therefore ~Copyable is the right tool." That's syllogism, not analysis.

The actual question is: **what invariant does the type system need to
encode?** For this bug, the invariant is "you cannot reach the actor
on a thread that doesn't hold the scope." That's a *lifetime*
invariant. ~Copyable encodes a *consumption* invariant (single use).
They are not the same.

This is a recurring failure mode for me: I pattern-match "structural
fix" to "use the most powerful Swift feature" instead of asking which
feature encodes the actual invariant. Memory note `feedback_structural_fix_preference`
says "leverage the LANGUAGE and type system to make issues like these
structurally impossible, and refactor-proof — no accidental changes
that break the fix." I quoted that in the proposal. I didn't apply it
at the right level.

The corrective: when proposing a structural fix, write down the
invariant in English BEFORE choosing the type. Then choose the type
that encodes THAT invariant. "X cannot exist after Y is destroyed" is
~Escapable. "X can be used at most once" is ~Copyable consuming.
"X requires proof of Y" is a generic constraint or a witness type.
"X can only be created via Y" is a private initializer plus a
factory. These are not interchangeable.

**2. Empirical negative results are first-class evidence.**

My V3 (1000 iterations, 0 bugs) wasn't a failure of the experiment.
It was a successful refutation of one hypothesis (memory ordering in
the simple case) and an implicit confirmation of another (whatever's
broken needs more code to trigger). I should have written it up
immediately as a finding, not kept reaching for V4 and V5.

The retrospective lesson: when an experiment's first variant gives a
clean signal (positive or negative), the next variant should EITHER
test a different hypothesis OR stop. Adding minor variations to the
same test is asking the same question louder. If V1 said "no bug
here," V2 needs to ask a different question, not repeat V1 with
slightly more pressure.

This is mostly the same pattern as the prior session's "debug-prints
ladder" — a diagnostic tool gives you ONE signal per invocation. The
signal is the answer; trust it.

**3. Asking for the constraints before designing the solution.**

The handoff brief was specific: no atomics, no `nonisolated(unsafe)`,
no existentials, type-system enforced. I read this as "design
constraints" and started designing. What I missed: the user had a
*shape* preference that wasn't in the brief but came out the moment I
showed a solution ("I'd rather NOT add new checks"). The
"no-new-checks" preference would have eliminated Option D before I
wrote it.

The retrospective lesson: when the brief lists constraints, treat
them as a partial spec, not a full one. There are always implicit
constraints (the user's aesthetic preferences, what shape of code
they want to maintain, what they consider a "real" fix vs a
"workaround"). Surface those before writing 32 KB of design. The
~30-second sanity check is "before I write this — does the shape feel
right? Are we adding code or removing code?" The user values
deletion. I proposed addition. That mismatch was a 90%-of-effort
mistake I could have caught with one question.

**4. The audit DEFERRED is a real outcome, not a failure.**

The investigation parked without a fix. That feels like incomplete
work, but it isn't. The session produced:
- A confirmed reproduction of the bug
- A documented negative experiment
- A 5-finding audit section recording the structural defect
- A full design proposal (Option D) AND the user's rationale for
  rejecting it
- A clear next-session direction (deletion-only, possibly bundled
  with Tier 0)

The next session can pick this up cold and not lose any context. That
IS the deliverable. "Park as DEFERRED with full context" is a valid
session outcome when the right next step requires a decision the
session isn't authorized to make. The mistake would be parking
without the context, forcing re-investigation.

## Action Items

- [ ] **[skill]** issue-investigation: add a "before designing,
  surface aesthetic constraints" rule. When a user asks for a
  structural fix, ask one clarifying question about the *shape* of fix
  they want (additive vs subtractive, runtime vs compile-time, new
  types vs deletion) BEFORE writing the proposal. Save the 32 KB
  proposal that's going to get rejected for shape reasons.

- [ ] **[skill]** experiment-process: add explicit guidance that an
  experiment's first clean signal (positive or negative) is the
  result. Subsequent variants should test a *different* hypothesis,
  not the same hypothesis with more pressure. V1+V2+V3 testing the
  same thing is a smell, not thoroughness.

- [ ] **[research]** What is the canonical Swift idiom for "this
  reference cannot be used after that scope ends" when the type is a
  class (heap reference) and must be Sendable? `~Escapable` doesn't
  compose with `Sendable`. The closest answers are: (a) make the
  class non-Sendable and pass a `~Copyable, ~Escapable` view, (b) use
  a generation counter / lifetime token, (c) make the public API
  closure-scoped only (no extractable scope). The L1/L2/L3 discussion
  in this session hit the same wall — write up the design space so
  the next investigation doesn't re-derive it.
