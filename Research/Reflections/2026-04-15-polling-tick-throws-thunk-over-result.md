---
date: 2026-04-15
session_objective: Refine Kernel.Thread.Executor.Polling's tick signature to surface wait failures, restoring the EINTR/ENOMEM/EAGAIN/fatal policy that Phase 3a dropped
packages:
  - swift-executors
  - swift-io
status: processed
processed_date: 2026-04-16
triage_outcomes:
  - type: skill_update
    target: implementation
    description: "Added [IMPL-092] throws(E) Thunk Parameters Over Result<T, E> for Callback Outcomes"
  - type: skill_update
    target: handoff
    description: "Added [HANDOFF-016] Proposal Staleness vs Work Staleness"
  - type: research_topic
    target: event-fake-controller-poll-error-injection.md
    description: "Should Fake.Controller gain poll-error injection for full tick→retry→wait integration testing?"
---

# Polling Tick: throws(E) Thunk Over Result — Language Semantics as Ecosystem Default

## What Happened

Session goal: execute `HANDOFF-polling-error-handling.md` — change Polling's tick parameter so the consumer, not the executor, owns wait-failure classification. The handoff proposed `Result<UnsafeBufferPointer<Kernel.Event>, Kernel.Event.Driver.Error>`. User overrode that mid-implementation with "we should use LANGUAGE SEMANTICS so throws see /implementation. dont use Result."

Final signature shipped:
```swift
private let tick: @Sendable (
    () throws(Kernel.Event.Driver.Error) -> UnsafeBufferPointer<Kernel.Event>
) -> Outcome
```

Two commits landed on `main` in both sub-repos (no branch — `main` was already 16+ commits ahead of origin in swift-io and used as the working branch; user asked "why checkout?" when I proposed `polling-error-result`):

- **swift-executors `c296df5`** — Polling tick becomes a `throws(E)` thunk. Run loop captures wait outcome into `let count: Int` and `let waitError: Kernel.Event.Driver.Error?` (definitely-initialised in both do/catch branches), then hands a closure that either re-throws the captured error or returns an `UnsafeBufferPointer` into the current `eventBuffer`. The `Kernel.Thread.yield()` that Phase 3a left in the run loop's catch is gone — the executor no longer classifies errors.
- **swift-io `b21c3657`** — Loop's tick becomes `{ [weak self] wait in ... do throws(Kernel.Event.Driver.Error) { let events = try wait(); self.dispatchEvents(events); return .continue } catch { return self.handleWaitFailure(error) } }`. New private `handleWaitFailure(_:)` + `fatalCleanup(error:)`. New internal pure classifier in `IO.Event.Loop.RetryDecision.swift` — enum (`.retry`/`.yieldAndRetry`/`.halt`) + static `retryDecision(for:)` — isolates the EINTR/ENOMEM/`isEAGAIN`/default pattern match for unit testing.

Also this session, before starting the handoff work: user opted into "commit pre-existing work first" when I surfaced that both sub-repos had uncommitted in-flight changes from other sessions. Two cohesive commits landed before mine — `1529eea` (swift-executors audit-remediation: `shutdownNow`→`shutdown`, `wakeAll`→`wake.all`, typed `Index<Kernel.Thread>` cursors, file splits for Stealing.Worker/Options and Polling.Outcome) and `9fb26a73` (swift-io Phase 3b docs). Proposed both messages via AskUserQuestion with preview content before committing.

Verification: swift-executors 18/18 tests green, swift-io 51/51 tests green — run with an untracked `IO.Events.Concurrent.Ready.Tests.swift` from a concurrent session moved aside (that file has pre-existing `sending`/macro-expansion compile errors unrelated to this work), then restored. The RetryDecision tests added here cover EINTR→retry, ENOMEM→yieldAndRetry, EAGAIN via Linux (11) and Darwin (35) raw values →retry, ELOOP-style unknown platform code →halt, `.invalidDescriptor`/`.notRegistered`→halt.

Two compile errors emerged during implementation and were fixed:
1. `ambiguous use of 'posix'` — my test's `.posix(11)` was ambiguous between the `Kernel.Error.Code.posix(Int32)` enum case and the IO-Events-internal `Kernel.Error.Code.posix(Kernel.Error.Number)` static helper that becomes visible under `@testable import IO_Events`. Fixed with `.posix(Int32(11))`.
2. `public import of 'Kernel' was not used in public declarations or inlinable code` — test file had `public import Kernel`; downgraded to `import Kernel`.

Two feedback memories saved mid-session: `feedback_throws_not_result.md` (callback outcomes use `() throws(E) -> T` thunks, not `Result<T, E>`) and `feedback_handoff_branch_prescriptions.md` (handoff branch names are advisory when `main` is already a working branch).

## What Worked and What Didn't

**Worked — AskUserQuestion with concrete preview content for commit messages.** The dirty working trees in both sub-repos were a friction point where I could have over-stepped by auto-grouping and committing someone else's in-flight work with guessed messages. Proposing two draft commit messages with body bullets via `preview` let the user scan the scope and approve (or redirect) in one round-trip. The user's selection came back as "Approve both messages as shown" — no rework needed.

**Worked — pure classifier isolation for testing.** Breaking `handleWaitFailure` into two parts — a pure `static func retryDecision(for: Kernel.Event.Driver.Error) -> RetryDecision` and an instance method that applies side effects (`Kernel.Thread.yield()`, `fatalCleanup`) based on the classification — made the EINTR retry path testable without constructing a live `IO.Event.Loop` and a Fake event source. Seven unit tests land the policy coverage requested in the acceptance criteria. If I had inlined the switch into `handleWaitFailure`, the side effects would have forced either an integration test (non-trivial to write against the executor thread) or a hand-rolled mockable layer.

**Worked — `throws(E)` thunk pattern for callback outcomes.** After the user's override, the resulting API reads cleanly at consumer sites: `do throws(Kernel.Event.Driver.Error) { let events = try wait(); ... } catch { ... }`. Error propagation uses the language's primitive mechanism. The executor internally materializes the outcome into `let count: Int` + `let waitError: Kernel.Event.Driver.Error?` (effectively a Result at the storage level), but the interface between executor and tick is expressed as `throws(E)` — the preferred idiom per `[API-ERR-001]`.

**Didn't work — defaulting to the handoff's proposed Result signature.** The handoff was explicit ("Better design: push error policy to the consumer" with a Result-typed signature). I took it as the prescription rather than a proposal and started implementing the Result-based design. The user caught it with one sentence — "we should use LANGUAGE SEMANTICS so throws see /implementation. dont use Result." — before the edit was fully applied. The loaded `/implementation` skill (`[API-ERR-001]`) already prescribes typed throws over erased errors; the analogous preference for typed-throws thunks over Result-value surfaces was not spelled out in any single requirement I had loaded. The preference was available in principle but not operationalised in the specific case of "closure parameter that delivers success-or-error."

**Didn't work — initial read of the handoff's branch prescription.** The handoff said "Branch: `polling-error-result` in both swift-foundations (swift-executors, swift-io)." I proposed `git checkout -b polling-error-result` in both sub-repos. User rejected with "why checkout?" — both repos had `main` already ahead of origin, used as the working branch; a topic branch added friction without value after the pre-existing work was committed on `main`. The handoff's branch name was written by a prior session under assumptions about repo state that no longer held.

**Friction — untracked work blocking test runs.** An untracked file (`IO.Events.Concurrent.Ready.Tests.swift`) from a concurrent session had pre-existing `sending`/macro-expansion errors. Because it was untracked (not committed), `git stash` wouldn't hide it. To run the test target I had to move the file aside to `/tmp` and restore it after. This is a recurring shape: concurrent sessions on the same working tree leave partial work that breaks the build for agents who don't know which files are theirs. No better mitigation suggests itself beyond the existing "check `git status` early, ask before destructive actions."

## Patterns and Root Causes

### 1. "Language semantics" is a recurring override axis, and the operationalisation lags the principle

The user's one-sentence override encoded an ecosystem-wide preference that wasn't explicitly discoverable from a single requirement ID. `[API-ERR-001]` says throwing functions must use typed throws — that covers throwing functions. But the analogous rule for "a closure *parameter* that delivers an outcome" isn't spelled out: the mechanism could be `Result<T, E>`, two closures (`onValue` / `onError`), a typed-throws thunk (`() throws(E) -> T`), or a protocol witness. The prior handoff author picked Result; `/implementation`'s prevailing spirit says "use the language's throws mechanism where it fits."

This is the same shape as past sessions where "use ~Copyable by default" ([IMPL-064]) had to be promoted from an implicit preference to an explicit rule after multiple corrections. An ecosystem-wide design preference surfaces as a user override; the override gets absorbed into a specific feedback memory; eventually the pattern recurs often enough to warrant a skill-level rule. This session produced `feedback_throws_not_result.md` — the local-memory step. A skill update to `/implementation` is the generalisation step, if the pattern recurs.

Concretely, the rule would read: *"For callback APIs that deliver one-of (value, error) to a consumer closure, express the outcome as a `() throws(E) -> T` thunk parameter, not `Result<T, E>`. Internal storage of the outcome (where throws cannot express a value, e.g., before the thunk is invoked) may use Optional or a private enum; the interface remains typed throws."* That matches the `[API-ERR-001]` philosophy ("typed throws for error-domain expression") extended from function returns to callback parameters.

### 2. Handoff prescriptions are point-in-time proposals, not durable contracts

This session's two user overrides — branch name, Result signature — both came from the handoff document. The handoff was written in a prior session with then-accurate assumptions. By the time I resumed it: (a) `main` in both sub-repos had become a working branch, invalidating the branch prescription; (b) `/implementation` had refined the ecosystem's stance on error-propagation mechanisms, invalidating the signature prescription. The user overrode both.

General pattern: handoff documents encode proposals that fit the author's context. When the handoff is resumed more than a few hours later, any of its proposals might be stale. Agent default behaviour should be to treat handoff sections as *inputs to a current-state check*, not as binding specifications.

This matches `[HANDOFF-*]` skill's own framing — handoffs are task state, not durable architecture. But `[REFL-009]` only talks about *verifying the handoff's work was done*, not *verifying the handoff's prescriptions are still valid at resume time*. The branch and signature overrides in this session are a second kind of staleness: not "work already done" but "proposal no longer best."

### 3. Pure classifier + side-effecting applier is the general shape for testable policy

The `RetryDecision` enum + `retryDecision(for:)` static + `handleWaitFailure(_:)` instance method pattern generalises: whenever a policy involves both classification and side effects, splitting them yields a pure function that's trivially testable and a thin wrapper that's left untested (because the wrapper is visually obvious). The acceptance criteria asked for "swift-io tests still cover the EINTR retry path" — the classification tests satisfy the intent cheaply. A full integration test (executor thread + Fake error injection + timing assertions) would have cost an order of magnitude more code for marginal additional confidence.

Observation: this pattern already exists informally across the ecosystem (e.g., typed arithmetic's separation of `Cardinal.Subtract` tag — the operations — from the `.saturating`/`.exact` policies applied to results). It's a recurring shape worth naming.

## Action Items

- [ ] **[skill]** implementation: Add a rule under `[API-ERR-001]` or as a new `[IMPL-*]` that formalises the preference for `() throws(E) -> T` thunk parameters over `Result<T, E>` for callback APIs that deliver one-of-value-or-error. Reference `feedback_throws_not_result.md` as the provenance. Include the internal-storage note (Optional/enum for materialising outcome before callback invocation is fine; the interface is what matters).

- [ ] **[skill]** handoff (or reflect-session): Extend `[HANDOFF-*]` / `[REFL-009]` to name a second staleness axis — "proposal staleness" (branch name, API signature, tool choice) distinct from "work staleness" (Next Steps already done). When resuming a handoff, agents should treat prescriptions as proposals subject to current-state re-validation, not as binding specs. Specifically call out branch names and API signatures as common loci.

- [ ] **[research]** Investigate whether `IO.Event.Fake.Controller` should gain poll-error injection so the full tick→retry→wait cycle can be integration-tested, not just the `RetryDecision` classification. Current unit tests validate the mapping but never exercise the live Polling run loop under an EINTR sequence. Question: does the marginal confidence justify the test infrastructure cost, given that the classifier is pure and the wrapper trivial?
