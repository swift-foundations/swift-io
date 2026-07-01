---
date: 2026-04-17
session_objective: Execute the Kernel Completion Opcode enum-with-associated-values refactor dispatched via HANDOFF-kernel-completion-refactor.md.
packages:
  - swift-io
  - swift-kernel
  - swift-kernel-primitives
status: processed
processed_date: 2026-04-24
triage_outcomes: see reflections-processing run 2026-04-24
---

# Kernel Completion Opcode Enum Reshape — Implementation Session

## What Happened

Subordinate session executing the handoff dispatched by the supervisor (see
`2026-04-17-io-completions-cancel-target-bug-structural-fix.md`). Goal:
eliminate the defect class that produced the io_uring cancel-target hang by
restructuring `Kernel.Completion.Submission` so variant-specific fields are
unrepresentable for the wrong opcode.

**State verification against handoff.** Confirmed all three HEADs matched the
documented bug-fix commits (`2451b7a`, `6cbf626`, `22f5a303`) and that
pre-existing files listed under "Pre-Existing Code in Scope" all existed.
Working-tree changes in swift-io (`Audits/audit.md`, `Research/_index.md`,
`Sources/IO Core/IO.swift`, `Tests/IO Blocking Tests/IO.Blocking.Binding.Tests.swift`)
and swift-kernel (`Research/_index.md`) were identified as out-of-scope
pre-existing modifications.

**Architectural gap surfaced before coding.** The handoff's "7 files moved
L1→L3" list didn't account for `Kernel.Completion.Driver._submit` and
`Kernel.Completion.submit()` at L1 referencing `Submission`/`Event` in their
public type surface — moving Submission/Event to L3 without also moving
Driver/Completion would break L1 compilation. Surfaced three options via
`AskUserQuestion`:

1. Full completion machinery to L3 (Option A)
2. Keep Driver+Completion at L1 with generic abstraction (Option B)
3. Revert Key Decision 2 entirely (Option C)

Supervisor chose Option A and updated the handoff. Expanded scope to include
`Completion` resource, `Driver`, and `Notification` moves. User flagged the
namespace collision (`Kernel.Completion` as both namespace enum at L1 and
resource struct at L3) and deferred rename decision pending finesse check.

**Mid-refactor pivot.** Surfaced the namespace collision finesse options.
User responded: *"I'd rather we keep as much at L1 as possible. If Completion
needs to be a proper type, then it can double as both namespace AND that type."*
This reversed the direction — not full L3 move, but minimal reshape at L1.
`Kernel.Completion` stays at L1 as the ~Copyable struct (already the case;
Swift structs naturally double as namespaces for nested types). Only the
Opcode enum rewrite, Submission field cleanup, and deletion of bespoke
Address/Length/Offset wrappers remained. No file moves.

**Implementation across three repos.**

- **L1 `swift-kernel-primitives`**: Rewrote `Kernel.Completion.Submission.Opcode`
  from `RawRepresentable(UInt8)` struct to enum with associated values —
  `.read(address:length:offset:)`, `.cancel(target:)`, `.poll(events:)`, etc.
  Rewrote `Submission` to fields `{token, opcode, flags, bufferGroup}` —
  dropped `address`, `length`, `offset`, `events`, `cancelTarget`. Deleted
  `Submission.Address.swift`, `Submission.Length.swift`, `Submission.Offset.swift`.
  Updated tests; deleted `Submission.Length Tests.swift`.

- **L3 `swift-kernel`**: Rewrote `Kernel.Completion+IOUring.swift` with
  exhaustive `switch submission.opcode` pattern match. Adapter-local extension
  inits bridge `Memory.Address.Count → Kernel.IO.Uring.Length(UInt32)`,
  `Kernel.File.Offset? → Kernel.IO.Uring.Offset(UInt64)` (nil → `UInt64.max`
  sentinel at SQE fill), and `Token → Uring.Operation.Data`. Deleted the
  `submission.cancelTarget!` force-unwrap.

- **`swift-io`**: Collapsed `IO.Completion.Entry` from 9 fields to 5 — the
  `opcode: Opcode` field carries buffer address/length, offset, and interest
  via associated values. Rewrote `IO.Completion.Actor.submit()` and
  `submitAsyncCancel()` to build `Submission` with the appropriate opcode
  variant. `read/write/ready/close` construct `Entry` with
  `.read(address:length:offset:nil)`, `.write(...)`, `.poll(events:)`
  respectively. `submitAsyncCancel` uses `.cancel(target: targetID)` directly —
  no more routing the target through the stream-mode offset field.

**Validation.** macOS host (arm64) L1 tests: 89/89; swift-io: 63/63. Linux
Docker `swift:6.3` (aarch64): L1 tests 89/89; L3 `IOUring Integration Tests`
4/4; swift-io 64/64 including the Cancel Handshake suite (previously the
failure symptom) — `read on empty pipe returns after cancel CQEs` passes in
0.034 seconds.

**User-initiated follow-up refactor.** User flagged `IO.Event.Actor.makeTick(for:)`
as a `private static func` returning a closure — "should be an extension
init on the target type, not a static func on Self." Pattern already existed
in the sibling `IO.Completion.Actor` where the tick delegates to
`Kernel.Thread.Executor.Polling.Outcome.init(actorHandle:wait:)` — but
`IO.Event.Actor` still had the older `makeTick` shape. Moved the tick body
into an extension init on `Kernel.Thread.Executor.Polling.Outcome`. Widened
`state`, `dispatch`, and `cleanup` from `private` to `fileprivate` to reach
them from the same-file Outcome extension.

**Four commits landed on main across three repos.**
- `swift-kernel-primitives@2d8d7d0` — Opcode enum reshape
- `swift-kernel@d7030f1` — io_uring adapter
- `swift-io@3d086ba9` — Entry/Actor reshape
- `swift-io@c443ceca` — IO.Event.Actor Outcome extension init

Nothing pushed.

## What Worked and What Didn't

**Worked — surfacing the architectural gap before coding.** The handoff's
"7 files moved, 3 preserved" accounting missed the Driver/Completion type
dependency. Coding directly would have hit a compile error mid-refactor and
required unwinding. Surfacing via `AskUserQuestion` with three concrete
options cost one round-trip but prevented the unwind. Per [SUPER-011]'s
verification gate — it does its job when subordinate hits a premise-level
question.

**Worked — mirroring the `IO.Completion.Actor` pattern for `IO.Event.Actor`.**
When the user pointed at `makeTick`, the fix was obvious — the completion
actor already demonstrated the correct shape: extension init on `Outcome`
with `assumeIsolated` inside. Side-by-side symmetry guided the rewrite.
Pattern recognition from recently-written code was higher-signal than
skill-lookup.

**Worked — `fileprivate` widening pattern.** Both `IO.Completion.Actor`
(my earlier work) and `IO.Event.Actor` (this session) use the same widening
discipline: `dispatch`, `cleanup`, `state` go from `private` to `fileprivate`
to enable same-file extensions on target types. Minimal surface expansion;
no cross-file access granted.

**Didn't work — silently dropped `@_spi(Syscall) import` on L3 adapter
rewrite.** When rewriting `Kernel.Completion+IOUring.swift`, I preserved
`import Kernel_Core` and `import Linux_Kernel_IO_Uring` but dropped
`@_spi(Syscall) import Kernel_Completion_Primitives`. The omission was
invisible on macOS because the entire adapter body is `#if os(Linux)` —
the imports never need to resolve. Linux Docker surfaced the error at
`Event.Result.init(rawValue:)` (SPI-gated), 3456 compile steps in. Cost:
one full cold-cache Linux rebuild cycle (~15 minutes) to discover and fix.
Root cause: rewrite-by-replacement rather than rewrite-by-edit.

**Didn't work — initial test code used `Memory.Address(__unchecked: (), Ordinal(0x1000))`.**
User nudged: *"for tests, see /testing re expressiblebyliteral. see also
identity-primitives for guidance. we should not use (__unchecked: () except
in adapter inits."* Loaded `/testing` skill, found `[TEST-018]` and
`[TEST-025]` spelling out that test support modules provide
`ExpressibleByIntegerLiteral` on `Tagged` — so `let address: Memory.Address = 0x1000`
is the idiomatic form. Fixed ~8 test-code sites. Lesson: should have loaded
`/testing` before writing test code, not after being told.

**Didn't work — SPM parallel-compilation race on Linux.** Two separate cold
Docker builds surfaced different race variants:
- Run 1: `error: missing required module 'Property_Primitives_Core'` at step
  1893/2119
- Run 2: `error: no such module 'Bit_Primitives_Core'` at step 568/907
Full `.build` wipe + `swift test -j 4` (reduced parallelism) was the
reliable recipe. The default SPM parallelism on the 2xxx-target graph hits
module-resolution races that don't reproduce on macOS. Not a code bug —
environmental.

**Didn't work — premature process kill.** When a Linux build appeared to
hang (but was actually still running), killed `swift` processes with
`kill -9`. The tasks were just slow, not hung. Got a "completed with exit
code 0" notification seconds after the kill — the kill was either racing
the natural completion or killing the already-completed shell. Lesson:
the runtime notification system reports completion; don't pre-emptively
kill based on apparent inactivity. `Bash run_in_background` + notification
is the correct pattern.

## Patterns and Root Causes

**Pattern — cross-platform-guarded imports vanish silently.** Any `#if os(X)`
block imports are only load-bearing on X. Rewriting a file on platform Y
can strip an X-required import without any local diagnostic. This is a
*platform-asymmetric correctness* concern: the file compiles on Y but
catastrophically fails on X at a site that is often deep in the compile
graph. The [IMPL-COMPILE] axiom ("compiler as primary correctness
mechanism") doesn't apply here because the compiler running on Y doesn't
see the violation. Defense: diff imports against baseline when rewriting
platform-specific files; never rewrite-by-replacement for files with
platform guards.

**Pattern — sibling-type inconsistency after partial refactor.** The
`Outcome.init(actorHandle:wait:)` pattern was correct in
`IO.Completion.Actor` (recent) but not adopted in `IO.Event.Actor` (older).
Two sister actors with the same responsibility (execute tick, bridge to
actor isolation via `assumeIsolated`) diverged in how they structure the
tick closure. The user caught this symmetry break and requested alignment.
Lesson: when working on one of a pair of sibling types, check the other
for the same pattern — the refactor scope should include sibling
normalization, not just the named target.

**Pattern — Swift's struct-as-namespace eliminates namespace-vs-type collision.**
The supervisor's original instinct (Option A: move everything to L3 because
of namespace collision) was correct under a default assumption that
namespaces must be caseless enums. User's pivot recognized that Swift
structs naturally serve both roles: `Kernel.Completion` the struct holds
the resource body AND namespaces the nested types (`Token`, `Capabilities`,
`Error`, `Event.Result`). No typealias bridge, no rename, no L1→L3 move —
just let the struct be both. This is already the shape `Kernel.Completion`
had before the refactor; the "collision" was a phantom.

**Pattern — user preference signals reverse handoff direction.** The
handoff was explicit about Option A ("full machinery to L3"). Mid-session
the user said "keep as much at L1 as possible." Handoffs describe what was
believed correct at the time of dispatch; user preferences expressed
mid-session override that framing. Treated the user's message as
authoritative and narrowed scope accordingly. The narrower scope produced
a cleaner outcome — zero file moves, behavior-preserving reshape.

**Pattern — SPM parallel-build races on Linux for large graphs are not
code bugs.** The `-j 4` + clean-build recipe is reproducible and reliable.
Worth documenting in the platform skill so future Linux Docker validations
don't repeat the diagnosis.

## Action Items

- [ ] **[skill]** implementation: Add a rule under [IMPL-COMPILE] addressing
  platform-guarded imports: when rewriting a file that contains `#if os(X)`
  blocks, imports inside or supporting those blocks MUST be preserved
  verbatim and verified against the pre-rewrite version on platform X.
  Provenance: this session's silent `@_spi(Syscall) import
  Kernel_Completion_Primitives` drop.

- [ ] **[research]** Document the SPM parallel-compilation race pattern on
  Linux Docker: reliable invocation (`swift test -j 4` + full `.build`
  wipe), reproducibility conditions (fresh container + cold cache + large
  package graph), and whether this is a `swift-build` bug worth filing
  upstream. Destination: `swift-foundations/swift-io/Research/` or ecosystem
  `/platform` skill.

- [ ] **[skill]** testing: Add a cross-reference from `/existing-infrastructure`
  for constructing `Memory.Address`, `Memory.Address.Count`, `Kernel.File.Offset`
  in tests → `/testing` [TEST-018] literal conformances. The current
  `[INFRA-*]` catalogues primitives but doesn't route the reader to the
  test-support literal shortcut when the usage site is a test.
