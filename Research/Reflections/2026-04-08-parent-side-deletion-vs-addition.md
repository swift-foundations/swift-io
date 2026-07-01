---
date: 2026-04-08
session_objective: Resume swift-io after Phase 3 and resolve the release-mode actor-state visibility bug per HANDOFF.md (parent-side perspective)
packages:
  - swift-io
status: processed
processed_date: 2026-04-16
triage_outcomes:
  - type: skill_update
    target: implementation
    description: "Added [IMPL-086] Deletion-First Structural Fix"
  - type: skill_update
    target: audit
    description: "Added [AUDIT-017] Parking destination — DEFERRED with investigation pointer"
  - type: no_action
    description: "[experiment] ~Escapable+@Sendable composability — question captured in companion reflection action item; research covers via sendable-heap-ref-lifetime-idiom.md"
---

# Parent-side: Deletion vs Addition — Structural Fix Misalignment

> Companion to [`2026-04-08-actor-state-fix-deferred-structural-vs-runtime.md`](2026-04-08-actor-state-fix-deferred-structural-vs-runtime.md), which captures the same session from the *agent's* perspective. This entry is the *parent's* perspective — session orchestration, the proposal-cycle that drove the user to "I'm losing hope," and the parking decision.

## What Happened

Resumed swift-io's `HANDOFF.md` Next Steps. State verification showed Phase 3 complete, debug 379/379, three Shutdown tests failing in release mode, and a branching investigation `HANDOFF-actor-state-visibility-fix.md` waiting on a design proposal.

Spawned an investigation agent (general-purpose, Opus, background) with the branching handoff as its brief. Agent ran ~30 min and produced the proposal, two repro experiments, and a Findings section appended to the handoff. Agent's perspective is captured in the companion reflection — read that for the investigation details.

**Mistake 1 (~30 min in).** User asked "how long will this take? agent's been going for 30 minutes." I incorrectly grepped for "## Findings" in the handoff, matched "## Findings Destination" first, concluded the agent was stuck, recommended interrupting it. The user said yes, I stopped the agent. **Then I read the file properly and discovered the Findings section was in fact appended** — 25 lines below the "Findings Destination" match. The agent was actually doing supplementary verification work, not stuck. Apologized in-line and continued from the (complete) deliverable.

Reviewed the proposal. Recommended Option D (slip pattern). Asked for sign-off before touching `Sources/`.

User shared a separate analysis from a parallel agent in their other window. That agent also recommended Option D, but added a 5-minute validation spike (`Atomic<UInt8>` mirror in `Runtime.shutdown()` and `Runtime.register()`) to confirm the diagnosis before refactoring. I weighed the parallel agent's findings, agreed the spike was sound, and started writing the spike edit to `IO.Event.Loop.swift`.

**Mistake 2.** User rejected the spike: *"I actually think adding this Synchronization stuff is a regression, and is more likely pointing to more structural issues. I'd rather NOT add new checks, and instead fix the structure."*

Updated the existing memory `feedback_structural_fix_preference.md` to sharpen the rule: even temporarily adding sync primitives for *diagnostic* purposes is a regression when the bug itself is pointing to a structural issue.

Investigated the structural defect. Identified that `IO.Event.Selector.Scope` is `~Copyable, ~Escapable` but its `public let selector: IO.Event.Selector` punches a hole through the lifetime. Selector is freely Copyable+Sendable with two reference-type fields. Extracted selectors escape the scope's lifetime contract. Proposed L1/L2/L3 fixes (private selector field + scope-routed methods → full ~Escapable Channel → full Tier 0 redesign).

Did the audit the parallel agent recommended. Found that production code does not cross `Channel` across `Task` boundaries, but `Channel.split()` halves DO via `Channel.Storage` (`@unchecked Sendable`, holds `selector`). `Storage.close()` calls `selector.deregister(...)` — the latent path L1 wouldn't fix. Also discovered `~Escapable + @Sendable` closures don't compose in Swift 6.3, blocking the `withTaskGroup` patterns existing tests use.

Proposed L2+ (Channel ~Escapable, Storage stays Sendable, `Runtime.deregister` becomes idempotent, actor `state` field removed).

**Mistake 3.** User pushed back again: *"but this would still be adding registers etc. .... Im losing a little hope here."*

Pivoted to a deletion-only proposal: remove the actor `state` field, `enter()`, `State` enum, all state checks; delete the five Shutdown tests; accept a looser post-shutdown contract. ~25 lines removed from `Sources/`, ~180 from `Tests/`, zero additions. Acknowledged the latent issues this doesn't address (extracted selectors, Channel.split path, contract loosening).

User decided to **park, not land**: *"just document it via /audit so we can return to it later."*

Documented the bug as 5 findings under a new audit section `Memory Safety: Cross-Thread Actor State Visibility — 2026-04-08`, all DEFERRED. Updated `Research/_index.md` with entries for the proposal and the bumped audit date. Committed everything as one checkpoint (`81ba4388`): the proposal, the two experiments, the audit section, the index updates.

## What Worked and What Didn't

### Worked

- **Spawning the investigation agent in background.** Background mode let me continue with state verification and prepare the review while the agent worked. The deliverable was thorough and well-structured — better than I would have produced in the same time.
- **Updating memory inline when feedback came.** Sharpened `feedback_structural_fix_preference.md` immediately rather than queuing it for later. The sharper rule will catch this same misjudgment in future sessions before I write a 32 KB proposal.
- **Parking via `/audit`.** The audit framework's findings table format (with severity + status) was the right destination for "we know this exists, we know the constraints, we don't have a fix yet." It's durable, indexed via `Research/_index.md`, and lives next to the code it concerns. Far better than another HANDOFF file.
- **Single checkpoint commit at the end.** All session-produced artifacts in one commit, working tree clean, easy to point to.

### Didn't work

- **Misjudged the agent's status from a grep error.** See Mistake 1 above. Cost user trust briefly. Pattern: I should read files fully when checking on a background agent, not grep and decide.
- **Overcorrected toward complex structural fixes** after the user's first rejection. When they said "no atomics, fix the structure," my interpretation was "introduce more type-system structure" — slip pattern → L1 → L2 → L2-full → L2-pragmatic. Each was a different shape of *adding* types and methods. Five proposal iterations deep before understanding the user wanted *deletion*.
- **Asked for confirmation in circles** instead of converging. The user said "I'm losing a little hope here" — that was the explicit signal that my proposal-cycle wasn't producing convergence. I should have read it as "stop iterating, find the simple answer" not as "let me try another angle."
- **Reached for an Atomic mirror spike** for diagnosis. The existing memory `feedback_structural_fix_preference.md` already said "prefer structural over flags," and my interpretation that this only applied to production code was wrong. The user means it broadly — including for diagnostics.
- **Caught the Channel.Reader/Writer split path late.** Only noticed it because I read `Channel.Storage.swift` carefully after the Iteration test grep. Earlier proposals (L1, L2-narrow) would have left this latent. The audit prevented me from proposing a half-fix, but I had to be told to do the audit by the parallel agent.

## Patterns and Root Causes

### Pattern 1: Addition vs subtraction as a problem-solving direction

The shape of this session: every proposal I made *added* something. The slip pattern added a `~Copyable` type. L1 added `register/deregister` methods to Scope. L2 added a Channel API change. L2+ added an idempotency requirement. Even my "deletion-only" framing arrived after four iterations of additive proposals.

The user's `feedback_structural_fix_preference.md` was originally about preferring type-system structure over boolean flags. The implicit corollary I missed: **the structural fix is sometimes to remove existing structure, not add more.** A bug in a runtime-checked invariant can be fixed by removing the invariant (and the code that depended on it being checked) instead of by replacing the runtime check with a type-system check.

The diagnostic question I should ask first is not "how do I enforce this invariant via the type system" but "do I need this invariant at all? what would happen if I deleted both the check and the code that produced it?" If the answer is "we delete some tests and accept a looser contract," that's often the right move — Swift's type system doesn't have to defend every invariant; some invariants exist because we wrote them, not because they're load-bearing.

This shape is general. It applies any time someone proposes adding language-level enforcement to a problem. Ask: is the thing being enforced actually load-bearing, or is it a contract we wrote that we're now bending the language to maintain?

The agent's companion reflection arrives at the same insight from a different angle ("cargo-cult structural reasoning" — reaching for `~Copyable` because it's the most-praised feature, not because it encodes the right invariant). Two perspectives on the same shape: I was thinking too additively; the agent was thinking too type-system-feature-first. Both are forms of the same trap.

### Pattern 2: Confidence calibration on background agents

I have repeatedly wrongly inferred agent status from incomplete reads. In this session: I grepped for "## Findings" in the branching handoff, matched "## Findings Destination" first, concluded the agent never wrote the Findings section. I should have known better — the section was right there, 25 lines further down. The cost was low this time (I stopped the agent, which was about to finish anyway), but in another session it could mean interrupting genuinely useful work.

The pattern: when checking on a background agent, the temptation is to scan for "is the deliverable there yet" instead of reading the actual output. The fix is to read the file fully when checking, not grep and decide. Especially when the grep result is suspicious — "no findings section" should have prompted "let me read the whole file" not "the agent is stuck."

### Pattern 3: Audit framework as a parking destination

I had not previously thought of `/audit` as a way to *park work* rather than to *audit work*. The audit skill description ([AUDIT-011]) draws its scope as "audits check code against skill requirement IDs." But the swift-io actor-state-visibility section parked in this session is a finding-against-rule (memory-safety [MEM-SEND-001], [MEM-LIFE-001]) that happens to be DEFERRED rather than OPEN. The findings table format with severity + status is a natural fit for "we found this, we're not fixing it yet, here's why."

This is potentially generalizable: investigations that can't land in the current session should produce audit findings instead of new HANDOFF files. The audit file is durable, indexed, and lives next to the code it concerns. HANDOFF files are ephemeral, gitignored, and accumulate context-trap weight on every future session. The audit destination is structurally better.

## Action Items

- [ ] **[skill]** implementation: Add a heuristic for "deletion-first structural fix." When a bug is in a runtime-checked invariant, ask whether the invariant itself is load-bearing before designing language-level enforcement. If deleting the check + the contract + the tests that depend on it produces acceptable behavior, that's often the right structural fix — not adding `~Copyable` types or atomics or scope methods. Reference: this session's actor-state visibility investigation, where 5 proposal iterations of "add structure" preceded the realization that the right fix was "delete the field and the tests that test it."

- [ ] **[experiment]** swift-foundations: Test `~Escapable` + `@Sendable` closure composability in Swift 6.3. Specifically: can a `~Escapable` value be captured by `withTaskGroup`'s `addTask` body when the task lifetime is bounded by the group? The L2 fix path was abandoned partly because I assumed "no" without verifying. If yes (or if there's a known-working pattern), L2 becomes more viable as a future fix path. Template: reuse `Experiments/noncopyable-actor-driver-ownership/`.

- [ ] **[skill]** audit: Document `/audit` as a valid parking destination for investigations that don't land. Currently [AUDIT-011] "Scope Boundary" draws the line as "audits check code against skill requirement IDs." But this session's audit section parked findings-against-rules that happen to be DEFERRED rather than OPEN. The skill could explicitly document DEFERRED-with-investigation-pointer as a first-class audit output, distinct from audit-to-fix-now workflows. This would standardize how investigations are parked.
