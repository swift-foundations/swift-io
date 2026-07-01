---
date: 2026-04-03
session_objective: Replace Selector reply bridge with direct continuation passing to halve register/deregister thread crossings
packages:
  - swift-io
status: processed
processed_date: 2026-04-15
triage_outcomes:
  - type: no_action
    description: "[package] swift-io benchmark — execution task, not a knowledge outcome; already in HANDOFF step 8"
  - type: skill_update
    target: issue-investigation
    description: "Added [ISSUE-021] Reference Indirection for SIL Verifier Crashes — generalized the class-box workaround for MoveOnlyAddressChecker on ~Copyable enums"
  - type: no_action
    description: "[research] Swift 6.3 SIL workaround catalog — already captured in swift-institute/Research/swift-6.3-revalidation-status.md (RECOMMENDATION, Tier 2)"
---

# Direct Continuation Passing Simplifies the CQ Waiter Pattern

## What Happened

Picked up HANDOFF-selector-waiter-pattern.md. The handoff proposed replicating the CQ Waiter pattern (atomic state machine + Storage class + void-signal continuation) for Selector register/deregister. During design, realized that registration payloads (`IO.Event.Registration.Payload`) and errors (`IO.Event.Error`) are both Sendable/Copyable — unlike CQ completion events which are ~Copyable. This meant a typed `CheckedContinuation<Result<Payload, Error>, Never>` could be passed directly through the `~Copyable` Request enum to the poll thread. No Storage class, no atomic state machine, no void-signal pattern needed.

Implemented: modified Request enum, Poll.Loop, Runtime, Topology, Selector. Removed Reply.Bridge, Reply.ID, Reply struct, replyLoop() Task, replies dict, replyCounter. Net -163 lines.

Hit a Swift 6.3 SIL crash (MoveOnlyAddressChecker) when `CheckedContinuation<Result<...>, Never>` appeared as an associated value in the ~Copyable Request enum. The `load [take]` of sibling values (e.g., `Interest`) was incorrectly flagged as a lifetime leak. Workaround: wrapped the continuation in a reference-counted `IO.Event.Registration.Continuation` class. The class reference is a simple pointer in SIL, sidestepping the verifier's tracking issue. Also needed `while let dequeue` instead of closure-based `drain { }` on the poll thread's shutdown path, and a static helper for the Runtime's fatal-error drain.

One test failure caught a semantic change: the "shutdown drains pending replies with shutdownInProgress (race)" test expected `.shutdownInProgress` but the poll thread's shutdown now resumes with `.failure(.invalidDescriptor)`. Fixed by moving the `guard state == .running` check before the result switch in `register()`, so any result during shutdown becomes `.shutdownInProgress`.

Steps 1–7 of the handoff are complete. Step 8 (benchmark verification) remains.

## What Worked and What Didn't

**Worked well:**
- The design insight that Copyable payloads allow direct continuation passing eliminated two entire abstraction layers (Storage + atomic state). The plan was confirmed as "better than what I suggested in the handoff" by the developer.
- The three-way shutdown/drain analysis (normal shutdown: poll thread handles; fatal error: Runtime drains; fire-and-forget: nil continuation) was correct on first pass and survived testing.
- The error type mapping (leaf `IO.Event.Error` in continuation, Runtime wraps to `IO.Event.Failure`) was clean and consistent.

**Didn't work:**
- Missed four call sites (`Channel.swift`, `Channel.Storage.swift`, channel test, and the `Selector.swift` construction) using `replyID: nil` — discovered only at build time. A grep for `replyID` across all sources before editing would have caught these upfront.
- The SIL crash required three iterations to work around (closure-based drain → while-let loop → static helper → class box). Each attempt required a full rebuild cycle. The root cause — complex generic types confusing the MoveOnlyAddressChecker in ~Copyable pattern matches — was not obvious from the error message alone.

## Patterns and Root Causes

**Copyability determines pattern complexity.** The CQ Waiter pattern exists because `IO.Completion.Event` is ~Copyable (it can carry a descriptor). The void-signal continuation + Storage indirection is necessary only when the result type can't be the continuation's generic parameter. When results are Copyable, the continuation can carry them directly. This is a general principle: before replicating a pattern, check whether the original's constraints still apply. The handoff proposed atomic CAS + Storage; the actual constraint (Copyable vs ~Copyable result) pointed to a simpler solution.

**Swift 6.3 MoveOnlyAddressChecker is a recurring obstacle.** This is now the third workaround in swift-io: `@_optimize(none)` on Unbounded channel, `Registration.Continuation` class box, and `while let dequeue` / static helper. All share the same root cause: the SIL verifier can't track value lifetimes through complex ~Copyable patterns. The workarounds all reduce the complexity visible to the verifier (disable optimization, use reference indirection, avoid closures, avoid actor isolation). All three are annotated with "revisit on Swift 6.4+".

**Shutdown semantics must be preserved across architectural changes.** Moving continuation ownership from the Runtime (replies dict) to the Request (MPSC queue) changes who resumes during shutdown. The existing test caught this immediately. The fix (check state before inspecting result) is correct but the need for it wasn't anticipated during design.

## Action Items

- [ ] **[package]** swift-io: Run register/deregister benchmark to verify ~2.6ms target (handoff step 8)
- [ ] **[skill]** issue-investigation: Add pattern for "SIL crash in MoveOnlyAddressChecker with ~Copyable enums" — reference indirection via class box as known workaround
- [ ] **[research]** Catalog all Swift 6.3 SIL workarounds in swift-io for batch verification when 6.4 ships
