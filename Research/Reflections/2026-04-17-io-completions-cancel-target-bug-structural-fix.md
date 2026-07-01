---
date: 2026-04-17
session_objective: Diagnose and fix the Linux io_uring integration test hang, then design the structural follow-up that makes the defect class unrepresentable.
packages:
  - swift-io
  - swift-kernel
  - swift-kernel-primitives
status: processed
processed_date: 2026-04-24
triage_outcomes: see reflections-processing run 2026-04-24
---

# IO Completions: Cancel-Target Bug, Minimum-Delta Fix, and L1→L3 Structural Follow-up

## What Happened

Session inherited a HANDOFF.md describing a Linux io_uring integration-test hang on Docker `swift:6.3`. Full-suite reportedly hung at "Suite Integration" → "pipe read/write round-trip", but the handoff's own diagnostic trace was inconclusive (output interleaving across concurrent tests, opcode mismatches suggesting but not proving a specific bug).

**Diagnosis via live zombie evidence.** Rather than reasoning from code or re-reproducing from scratch, inspected the three zombie Docker containers from the previous session (2–4h uptime, still hung). `/proc/<pid>/fdinfo/<io_uring_fd>` showed:

- `SqHead=SqTail=15`, `CqHead=CqTail=14` — rings idle
- eventfd counter = 0 — no pending wakeup
- `PollList: op=22, task_works=0` — one `IORING_OP_READ` parked in the kernel's internal poll list

Thread state via `/proc/<pid>/task/<tid>/syscall` confirmed the Completion executor thread was blocked in `read(fd=46, ...)` on the registered eventfd. Classic "kernel is polling a pipe; nobody's writing; cancel never fired" pattern.

**Code trace.** `IO.Completion.Actor.submitAsyncCancel` stored the targetID via `offset: Int64(targetID.rawValue)` into Entry. `Actor.submit()` translated `entry.offset → submission.offset`. But the L3 io_uring handler in `Kernel.Completion+IOUring.swift:119-125` read `submission.address._rawValue` for the cancel target — not `.offset`. `Submission.Address.none = _rawValue: 0`. Every cancel SQE targeted `user_data = 0`. Kernel found no matching in-flight op, returned `-ENOENT`, left the original READ parked in PollList forever.

**Why full-suite-only.** `IO.completionsTest()` on Linux routes to `IO.Completion.Actor.shared()` — a process-wide singleton. The Cancel Handshake suite runs before Integration in the default order; its cancel failure poisons the shared ring's PollList; subsequent Integration tests hang because they share the ring. `--filter "Integration"` excludes Cancel Handshake, so the filtered run passed cleanly (0.007s) and the handoff's framing was wrong: it wasn't "Integration hangs" but "Cancel Handshake poisons the shared ring."

**Validation probe.** 1-line L3 handler change (read `submission.offset.rawValue` instead of `submission.address._rawValue`). Cancel Handshake test went from hang → pass in 0.015s. Theory confirmed.

**Minimum-delta structural fix shipped.** Reverted probe; added `cancelTarget: Token?` field to `Kernel.Completion.Submission` at L1. Three commits on main:
- `swift-primitives/swift-kernel-primitives 2451b7a` — field + L1 unit test
- `swift-foundations/swift-kernel 6cbf626` — handler reads `submission.cancelTarget!`
- `swift-foundations/swift-io 22f5a303` — `Actor.submit` routes entry.offset → submission.cancelTarget for `.cancel`

Linux Docker `swift:6.3` clean rebuild: 64/64 tests pass.

**Design conversation for follow-up.** User pushed past the field-add fix: "is this the best we can do? Have you considered `~Copyable`/`~Escapable`?" Acknowledged ownership features don't address discriminated-union shape; the right answer is `Opcode` as enum-with-associated-values. User then corrected layer placement: "where would this enum be placed?" — pushed me from L1 to L3, matching the existing architecture (L1 = universal vocabulary, L3 = unification). User then corrected type invention: "for address, length, offset, count, see `/implementation` and `/existing-infrastructure`" — `Memory.Address`, `Memory.Address.Count`, `Kernel.File.Offset?` all exist at L1 already; no new primitives needed.

**Handoff dispatched to subordinate under `/supervise`.** Wrote `HANDOFF-kernel-completion-refactor.md` with 6 key decisions, 9 next steps, and 8 typed supervisor ground rules. Subordinate verified state, then caught a real architectural gap: `Kernel.Completion.Driver._submit` and `Kernel.Completion.submit()` at L1 reference `Submission` and `Event` in their public type surface — moving Submission/Event to L3 without also moving Driver/Completion breaks L1 compilation. Authorized Option A (full completion machinery to L3; L1 retains only opaque primitives: Token, Capabilities, Error, Event.Result, Buffer.Group, namespace root). Updated the handoff doc accordingly.

**Adjacent work.** Consolidated 42 off-main branches to main across swift-primitives and swift-foundations (mostly `unsafe-audit` linear-ahead of main); deleted `swift-svg-rendering-worktree`; advised on `swift-queue-primitives` (detached HEAD with revert+reapply cycle — linear ahead of main, FF works); noted the `sync-gitignore.sh` canonical approach for ecosystem-wide gitignore alignment.

## What Worked and What Didn't

**Worked — `/proc/fdinfo` as diagnostic tool.** The live zombie containers held exactly the hang state. Reading `fdinfo` for the io_uring fd surfaced `op=22 READ in PollList` directly. No speculation, no code-bisection; the kernel's own bookkeeping told us what was wrong. Saved hours over the "add prints, rebuild, re-run Docker" loop that the prior session attempted.

**Worked — minimum-delta fix first, refactor second.** The `cancelTarget: Token?` field is less principled than the enum but is validated green and landed on main. If the refactor discovers problems, main still has the fix. `git bisect` distinguishes cleanly between the two. The user's Q4 decision (landing order (a)) was right.

**Worked — handoff+supervise composition.** The subordinate verified state against handoff, caught the layer-violation gap, and surfaced a question rather than coding through it. That's exactly the `[SUPER-011]` verification gate doing its job. Without ground rules + verification, the subordinate would have hit a compile error mid-refactor and had to unwind.

**Didn't work — I proposed inventing L1 primitives without consulting `/existing-infrastructure` first.** Address/Length/Offset/Count all exist in the ecosystem as `Memory.Address`/`Memory.Address.Count`/`Kernel.File.Offset`. The catalog is exhaustive and linked from CLAUDE.md. I skipped the lookup because the types "felt simple enough to invent." They weren't. User corrected in two words ("see `/existing-infrastructure`"), which should have been my first move, not my third iteration.

**Didn't work — `[HANDOFF-014] Pre-Existing Code in Scope` treated as a labeling exercise.** I listed Driver/Completion/Notification as "Preserved" without verifying their declarations still compile after the planned moves. Driver._submit has `Submission` in its signature. The subordinate caught this on verification. The skill says to enumerate; it doesn't strongly say to compile-check. My handoff had the bomb; the supervisor block made it a surface-able question rather than a failure.

**Didn't work — first `docker ps` pass put fresh Docker runs behind 3+ zombies holding the host `.build` lock.** Build planning hung for several minutes before I realized the contention. The zombies were useful evidence but also actively blocking my fresh reproduction. Should have checked for prior containers before kicking off a new one.

## Patterns and Root Causes

**Pattern: Sentinel-encoded optional state is a symptom of missing variant structure.** `Submission.Address.none = 0`, `Submission.Offset.current = UInt64.max` — these sentinels exist because `Opcode` is a `struct: RawRepresentable<UInt8>` with per-variant fields all living as flat struct members. For any opcode, every field must be present; "not applicable" needs an encoding. Sentinels leak (`.none = 0` → cancel targets user_data=0 → kernel -ENOENT). The cancel bug was the specific failure; the shape is the defect generator.

The enum-with-associated-values refactor eliminates the class. `.cancel(target: Token)` requires the target, admits no other fields. `.read(address:, length:, offset:)` binds its three fields to itself. Wrong-field-on-wrong-variant becomes a compile error. This isn't the only optional-sentinel-as-discriminated-union-in-denial in the ecosystem; the pattern generalizes.

**Pattern: `/existing-infrastructure` is a category-1 infrastructure question.** In a mature ecosystem the default should be "this already exists; locate it" rather than "this is simple; create it." My Address/Length/Offset/Count proposal happened because I didn't consult the catalog first. The skill's `[INFRA-020]` decision tree for `Int(bitPattern:)` is the right pattern — an entry-point question ("Need `Int` for stdlib API?") that routes to the right overload. A parallel "Need a typed numeric wrapper for a new subsystem?" tree would have caught my mistake.

**Pattern: Pre-existing-code-in-scope is a compile-check, not a label.** `[HANDOFF-014]` says to enumerate Preserved/Moved/Deleted. What's missing: the "Preserved" list must survive compilation after the moves and deletions. My handoff's "3 Preserved" included files that public-reference types being moved. The subordinate's state-verification step caught this only because the supervisor block + verification gate forced the check. Without the block, the failure mode would be: subordinate begins moves, build breaks mid-refactor, unwind.

**Pattern: Shared singleton actors are cross-test-pollution hazards.** `IO.Completion.Actor.shared()` is process-wide. Every `IO.completionsTest()` on Linux uses it. State leaks between tests. A test that fails to cleanly complete its cancel handshake leaves a READ parked in the kernel's PollList; subsequent tests using the same ring inherit the poison. The handoff's framing ("Integration test hangs") was technically incorrect — Integration was the victim, not the cause. Full-suite-only hangs on filtered-passes-clean is the smoking-gun signature of singleton-actor state leakage.

## Action Items

- [ ] **[skill]** handoff: Strengthen `[HANDOFF-014] Pre-Existing Code in Scope` with an explicit compile-verification sub-requirement. For each file labeled "Preserved," the handoff author MUST verify its declarations do not reference any type being moved or deleted. Today's session: my handoff listed Driver/Completion as "Preserved" without this check; the subordinate's state-verification caught the layer-violation on resume. The skill should make the check mechanical ("grep the Preserved files for the Moved type names; any hit is a defect").

- [ ] **[skill]** existing-infrastructure: Add a domain-specific decision tree — "Before creating `Address`/`Length`/`Offset`/`Count` in a new subsystem, check the memory/kernel primitive families." Today's session: I proposed four L1 wrappers despite `Memory.Address`, `Memory.Address.Count`, `Kernel.File.Offset` all existing at L1. The current `[INFRA-020]` entry-point is by stdlib-call-site symptom (`Int(bitPattern:)`); a parallel "by new-type-proposal" entry-point would increase the lookup hit rate.

- [ ] **[package]** swift-io: Document `IO.Completion.Actor.shared()`'s cross-test-pollution risk in the IO Completions README (and the Test Support doc if separate). `IO.completionsTest()` routes to `.shared()` on Linux. Any test that leaks in-flight SQEs poisons subsequent tests sharing the actor. Either expose a per-suite isolated-actor factory, or document the ordering hazard prominently — today's bug was visible only in full-suite runs precisely because of this.

## Session Artifact Cleanup

**Handoff files triaged (per [REFL-009]):**

- `/Users/coen/Developer/swift-foundations/swift-io/HANDOFF.md` — DELETED during swift-io bug-fix commit `22f5a303`. Described the now-resolved io_uring hang.
- `/Users/coen/Developer/swift-foundations/swift-io/HANDOFF-kernel-completion-refactor.md` — LEFT IN PLACE. Work is in progress: subordinate has completed partial reshape of `Submission` and `Opcode` at L1 (not yet moved to L3); Option A (full completion machinery to L3) authorized and embedded in the doc mid-resumption. Contains 8 supervisor ground-rules entries, all PENDING VERIFICATION — subordinate has not yet reached the validation steps. Per `[REFL-009]`: "Some items remain, OR any ground-rules entry unverified → leave the updated file."

**Audit findings:** no `/audit` invocation this session; `[REFL-010]` skipped.
