---
date: 2026-04-17
status: RECOMMENDATION
packages:
  - swift-kernel-primitives
  - swift-kernel
  - swift-io
  - swift-foundations
techniques:
  - ecosystem-type adoption
  - discriminated-union → enum-with-associated-values
provenance:
  - 2026-04-17 Kernel.Completion.Submission.Opcode refactor (swift-kernel-primitives@2d8d7d0, swift-kernel@d7030f1, swift-io@3d086ba9, swift-io@c443ceca)
  - HANDOFF-ecosystem-refactor-inventory.md
---

# Ecosystem Refactor Opportunities — Workspace Inventory

## Goal

Inventory further opportunities to apply the two techniques validated by the
`Kernel.Completion.Submission.Opcode` refactor across the
swift-primitives / swift-standards / swift-foundations workspace:

1. **Ecosystem-type adoption** — replace bespoke `RawRepresentable` /
   `struct X { let _rawValue: UInt32 }` wrappers with the L1 primitives the
   ecosystem already provides (`Memory.Address`, `Memory.Address.Count`,
   `Kernel.File.Offset`, `Kernel.Descriptor.Interest`,
   `Coordinate.X<Space>.Value<T>`, `Magnitude<Space>.Value<T>`,
   `Tagged<Tag, Ordinal>`, `Tagged<Tag, Cardinal>`).
2. **Discriminated-union → enum-with-associated-values** — where a struct
   carries a `kind` / `opcode` / `type` discriminator alongside fields whose
   meaning is variant-specific (only used for some discriminator values),
   rewrite as an enum whose cases carry the per-variant data as associated
   values, making variant-wrong field combinations unrepresentable at the
   type level.

## Headline Finding

**The workspace is in good shape.** The Submission.Opcode refactor was the
major hot spot; the remaining surface is largely either (a) already adopting
ecosystem types via `Tagged` typealiases, (b) already using
enum-with-associated-values for discriminated families, or (c) deliberately
spec-faithful at L2 / shell+values at L1 per `[PLAT-ARCH-013]`.

Of the entire `swift-kernel-primitives` Sources tree, only **1 confirmed
discriminated-union candidate** emerged (B1, `Kernel.Completion.Event.Result`).
The originally-proposed Tagged-adoption candidates A1 (`Inode`) and A2 (`Device`)
were **retracted** post-review — concept-named primitive-integer identifiers do
not fit the Tagged pattern (see retraction notes below). Two further items are
flagged as opportunities subject to a separate ecosystem decision (clock-time
alignment, coordinate adoption). swift-io, swift-kernel L3, swift-foundations
L3, and the L2 standards layer yielded **zero** new candidates beyond what the
validating refactor already landed.

## Prior Research — Cite Before Extending

Per `[HANDOFF-013]`, the following docs already cover adjacent terrain. New
work cites and extends rather than duplicates.

| Doc | Status | What it already establishes |
|-----|--------|----------------------------|
| swift-primitives/Research/[io-uring-semantic-flag-modeling.md](../../../swift-primitives/Research/io-uring-semantic-flag-modeling.md) | DECISION (2026-04-10) — IMPLEMENTED | The canonical precedent for both axes: 12 type relocations + 6 deletions, plus OptionSet→enum decomposition where flags were mutually exclusive. Establishes the rule "mutually-exclusive flags → enum; genuinely-combinable → OptionSet." |
| swift-foundations/swift-kernel/Research/[unified-completion-api-design.md](../../swift-kernel/Research/unified-completion-api-design.md) | IN_PROGRESS (2026-04-09 v2.0) | Sets the witness-driven (4 closures) vs case-dispatch (10 cases) framing. `.retag` / `.map` boundary conversion pattern as the canonical ecosystem-type adoption mechanism at L3↔L1 boundaries. |
| swift-foundations/swift-kernel/Research/[kernel-event-driver-zero-allocation-redesign.md](../../swift-kernel/Research/kernel-event-driver-zero-allocation-redesign.md) | DECISION (2026-04-09) | Demonstrates ecosystem-type adoption applied to in-out parameters (`(inout [Kernel.Event]) → Int`) and ~Copyable lifecycle automation. |
| swift-foundations/swift-kernel/Research/[conditional-compilation-public-enum-cases.md](../../swift-kernel/Research/conditional-compilation-public-enum-cases.md) | DECISION (2026-03-24) | Validates the principle that L2-typed enum cases stay conditional rather than absorbing platform variance into the L1 vocabulary. Bears on whether `Kernel.Completion.Event.Result` should encode platform errno semantics. |
| swift-foundations/swift-io/Research/[io-events-primitives-alignment.md](io-events-primitives-alignment.md) | RECOMMENDATION | Module-level primitives alignment audit (Deque→Queue, Slab+generation). Same shape of analysis at module rather than type granularity. |
| swift-foundations/swift-io/Research/[io-event-namespace-typealias-vs-enum.md](io-event-namespace-typealias-vs-enum.md) | DECISION (2026-04-01) | Defines `[API-NAME-004a]` namespace adoption typealias vs rename bridge. Necessary lens when judging whether a candidate type is a Tagged-wrapper or a domain-extension namespace. |
| swift-foundations/swift-io/Research/[completion-queue-ownership-redesign.md](completion-queue-ownership-redesign.md) | CONVERGED (2026-04-02 v2.0) | Demonstrates the orthogonal technique — discrimination via *type separation* (Submission vs Entry) rather than enum cases — and when to prefer it. |
| swift-primitives/swift-clock-primitives/Research/clock-time-unification.md | (referenced) | Bears on the `Kernel.Time.Deadline` candidate — clock/time vocabulary is under separate ecosystem investigation. |

## Axis A — Ecosystem-Type Adoption Candidates

### A1. ~~`Kernel.Inode` → `Tagged`~~ — RETRACTED

**Status: RETRACTED 2026-04-17**, post-publication review with user.

Originally proposed as `Tagged<Kernel.Inode, UInt64>` or `Tagged<Kernel, _Inode>`. Both are wrong:
- `Tagged<Kernel.Inode, UInt64>` is circular — the typealias being defined IS `Kernel.Inode`, so it cannot also serve as its own tag.
- `Tagged<Kernel, UInt64>` would collide with any other `UInt64`-backed kernel-namespaced identifier.

The Tagged adoption pattern requires the typealias name to be a *nested member* (e.g., `.ID`, `.Token`) of a separate tag namespace, as in `Kernel.User.ID = Tagged<Kernel.User, UInt32>`. `Inode` is the concept itself, not a member of an `Inode`-namespaced family. The bespoke `RawRepresentable` struct is the correct shape.

### A2. ~~`Kernel.Device` → `Tagged`~~ — RETRACTED

Same reasoning as A1. Concept-named identifiers backed by primitive integers are not Tagged adoption candidates.

**Generalization (recorded for future inventories)**: a `RawRepresentable` struct wrapping a primitive integer is a Tagged adoption candidate ONLY when (a) it is named as a nested member of a discriminating tag namespace (`.ID`, `.Token`, `.Count`), or (b) its raw value is itself a typed entity (e.g., `Tagged<Kernel, Memory.Address>` works because `Memory.Address` is already typed, distinguishing it from `Tagged<Kernel, Path>`). Standalone concept-named identifier types backed by primitive integers do not fit either pattern and should remain bespoke.

### A3. (Opportunity, not candidate) `Kernel.TTY.Size` — could adopt `Coordinate` / `Magnitude`

| Field | Value |
|-------|-------|
| Location | `swift-primitives/swift-kernel-primitives/Sources/Kernel Terminal Primitives/Kernel.TTY.Size.swift` |
| Current shape | `public struct Size: Sendable, Hashable { public let rows: UInt16; public let columns: UInt16 }` |
| Possible shape | Use `Coordinate.X<Kernel.TTY>.Value<UInt16>` / `Coordinate.Y<Kernel.TTY>.Value<UInt16>` or `Magnitude<Kernel.TTY>.Value<UInt16>` for both axes. |
| Risk | The handoff lists Coordinate / Magnitude as ecosystem types but does not establish whether terminal cell coordinates are the *intended* domain for them (those types likely target geometric / spatial dimensions). Adopting them here is a vocabulary-fit question, not a defect. |
| Confidence | LOW — flag as DEFERRED. Decide once `Coordinate<Space>` / `Magnitude<Space>` adoption guidance for non-spatial discrete dimensions exists. |
| Blast radius | 2 production files (`Size.swift`, `Size+Query.swift`) plus ISO 9945 termios |

### A4. (RESOLVED 2026-04-18) `Kernel.Time.Deadline` — alignment with swift-clock-primitives

| Field | Value |
|-------|-------|
| Location | `swift-primitives/swift-kernel-primitives/Sources/Kernel Time Primitives/Kernel.Time.Deadline.swift` |
| Current shape (post-revisit) | `public struct Deadline: Sendable, Hashable { public let instant: Clock.Continuous.Instant; static var never: Deadline }` plus typed arithmetic (`after(_:Duration, from:Instant)`, `hasExpired(at:Instant)`, `remaining(at:Instant)`). All `UInt64` / `Int64` raw-integer parameters and accessors were removed from the public surface. |
| Decision | **Adopted** — `Kernel.Clock.*.now()` + `Kernel.Time.Deadline` public API both typed on `Clock.Continuous.Instant` / `Clock.Suspending.Instant` / `Kernel.Clock.CPU.Process.Instant`. See `swift-primitives/swift-clock-primitives/Research/clock-time-unification.md#typed-return-revisit-2026-04-18` for the full decision trail (candidate evaluation, rationale, phased impact). |
| Blast radius (actual) | 11 source files across 4 repos (swift-primitives, swift-iso-9945, swift-windows-standard, swift-foundations). The earlier "28 files" figure counted every type reference; only API-call sites required migration — and of those, only 2 needed textual changes (one test threshold, one string-interpolation unwrap). |
| Follow-up | Future Phase 2 mechanical pass: rename `Kernel.Time.Deadline` → `Kernel.Clock.Continuous.Deadline` to make the clock namespace explicit (type is already continuous-clock-typed after Phase 1). Deferred. |

## Axis B — Discriminated-Union → Enum-with-Associated-Values Candidates

### B1. `Kernel.Completion.Event.Result` — sign-bit discriminator → enum

| Field | Value |
|-------|-------|
| Location | `swift-primitives/swift-kernel-primitives/Sources/Kernel Completion Primitives/Kernel.Completion.Event.Result.swift` |
| Current shape | `public struct Result: Sendable, Equatable, Hashable { @_spi(Syscall) public let rawValue: Int32 }` with `var isSuccess: Bool { rawValue >= 0 }` and `var value: Int32? { isSuccess ? rawValue : nil }`. |
| Discriminator | Implicit — sign of `rawValue`. Negative = `-errno`; non-negative = success-with-value (bytes / fd / 0 for nop). |
| Variant-specific fields | The `.value: Int32?` accessor IS the variant projection. Today it returns `nil` on the failure branch — exactly the "Optional only meaningful for some discriminator values" pattern the technique targets. |
| Proposed shape | `enum Result: Sendable, Equatable, Hashable { case success(value: Int32); case failure(errno: Kernel.Error.Number) }` with the L3 `Failure` extension translating the errno via the existing `Kernel.Completion.Event.Result+Failure.swift` table. |
| Refactor size | 1 file rewritten (~50 lines), 1 L3 extension file updated (`Kernel.Completion.Event.Result+Failure.swift`), 1 platform adapter (`Kernel.Completion+IOUring.swift`); test file (`Kernel.Completion.Event.Result Tests.swift`, ~15 sites). |
| Blast radius | 4 production files + 2 test files. Compact. |
| Risk | MEDIUM. (1) The `@_spi(Syscall)` rawValue is the io_uring CQE result field at the syscall boundary — the bridge (`init(rawValue: cqe.res)`) becomes a switch on sign. Boundary cost is one branch, not a real overhead. (2) The L1 type currently doesn't *know* about errno — the Failure mapping lives at L3. Encoding `errno: Kernel.Error.Number` in the L1 case requires `Kernel.Error.Number` to be visible to the Completion package. Verify dep direction. (3) Tests assume `.value` returns the raw Int32 for success; conversion is mechanical. |
| Aligned with prior research | Yes — directly extends `unified-completion-api-design.md` (`.retag`/`.map` boundary conversion pattern) and mirrors the Submission.Opcode reshape (the partner reshape Submission/Event would naturally pair with). |
| Blockers | Verify Kernel.Error.Number is reachable from Kernel Completion Primitives without a tier inversion. If not, the enum encodes raw `errno: Int32` and the L3 layer translates downstream — same shape, internal field type changes only. |
| Confidence | HIGH (with the caveat that partner Submission/Event symmetry should be considered when sequencing) |

### B2. (Considered as opportunity, not candidate) `Kernel.Time.Deadline` `.never` sentinel

The `.never = Deadline(nanoseconds: .max)` sentinel could become a case of an
enum (`case at(UInt64) / case never`). This is a real Axis B shape — sentinel
discriminator with one branch interpreting the field, the other ignoring it.

| Field | Value |
|-------|-------|
| Risk | This is the same type as A4. Same DEFERRED reasoning — defer to clock-time-unification. |
| Confidence | LOW — DEFERRED |

## Considered & Rejected

These were inspected and intentionally NOT flagged. Recording them so a future
session does not re-derive the rejection.

### Tagged-wrapper rejections

| Type | Reason for rejection |
|------|---------------------|
| `Kernel.Socket.Backlog` (Int32 RawRepresentable) | Spec-faithful: maps to POSIX `listen(int backlog)`. Semantic distinction from `Memory.Address.Count` — queue depth, not byte count. Signed Int32 prevents `Tagged<_, Cardinal>` substitution. |
| `Kernel.Socket.Descriptor` (UInt64 / Int32 platform-conditional `_raw`) | Per `[PLAT-ARCH-005]` and `[PLAT-ARCH-015]` — descriptors are platform-native types; the platform-conditional storage is the canonical pattern, not a refactor candidate. |
| `Kernel.Termios.Attributes.Action` (internal Int32) | Internal-only; spec-faithful POSIX `tcsetattr` action codes. |
| `Kernel.Completion.Submission.Flags` (UInt32 OptionSet) | `[PLAT-ARCH-013]` shell + values pattern — L1 shell + L3 platform-specific constants. Correct as-is. |
| `Kernel.Completion.Event.Flags` (UInt32 OptionSet) | Same pattern. |
| `Kernel.Descriptor.Interest` (UInt8 OptionSet) | Canonical interest vocabulary; OptionSet semantics genuine (read+write composable). |
| `Kernel.Event.Options` (UInt8 OptionSet) | Same. |
| `Kernel.File.Permissions` (UInt16 OptionSet) | POSIX mode bits; OptionSet semantics genuine. |
| `Kernel.File.System.Kind` (UInt64 RawRepresentable) | `[PLAT-ARCH-013]` shell + values: L1 shell, L3 magic-number constants (`.ext4 = 0xEF53`, etc.). Refactor would lose the conditional-static-constant ergonomics. |
| `Kernel.Completion.Token` (`Tagged<Kernel.Completion, UInt64>`) | Already a Tagged typealias. Width is ABI-fixed to UInt64 by io_uring user_data — `Tagged<_, Ordinal>` (UInt) would break on 32-bit. Correct as-is. |
| `Kernel.Completion.Buffer.Group` (`Tagged<_, UInt16>`) | Already Tagged; UInt16 is io_uring's wire width. |
| `Kernel.User.ID`, `Kernel.Group.ID`, `Kernel.File.System.ID` (`Tagged<_, UInt32/UInt64>`) | Already Tagged; widths match POSIX uid_t / gid_t / fsid spec. |
| `Kernel.Event.ID` (`Tagged<Kernel.Event, UInt>`) | Already Tagged. |
| `Kernel.Memory.Address` (`Tagged<Kernel, Memory.Address>`) | Already Tagged; canonical adoption pattern. |
| All `Kernel.{Path,String,Memory.Allocation.Granularity}` typealiases | Already Tagged. |
| `Kernel.File.Direct.Requirements.Alignment.{Offset,Length,Buffer}` | Per the handoff's explicit question: these are **validation accessor** structs, not value wrappers. They hold a reference to the parent `Alignment` and provide `isAligned(_:)` / `isValid(_:)` methods. Orthogonal to `Kernel.File.Offset`. The naming overlap with `Kernel.File.Offset` is coincidental — the verification was warranted; the answer is "intentionally separate." |

### Discriminated-union rejections (already enum or correctly multi-field)

| Type | Reason for rejection |
|------|---------------------|
| `Kernel.File.Direct.Requirements` | Already enum: `.known(Alignment) / .unknown(reason: Reason)`. Variant data already in associated values. |
| `Kernel.File.Stats.Kind` | Already enum: `.device(Device) / .link(Link)` etc. |
| `Kernel.File.Direct.Capability` | Already enum: `.directSupported(Alignment) / .uncachedOnly / .bufferedOnly`. |
| `Kernel.File.Direct.Mode` | Already enum: `.direct / .uncached / .buffered / .auto(policy: Policy)`. |
| `Kernel.Completion.Submission.Opcode` | JUST refactored — the validating refactor itself. |
| `Kernel.Event` (id, interest, flags) | All three fields always meaningful; `flags` is a status modifier not a discriminator. |
| `Kernel.Completion.Event` (token, result, flags) | All three fields always meaningful. |
| `Kernel.Event.Driver.Registration` (~Copyable; descriptor + interest + armedInterest) | All three fields always meaningful — armedInterest tracks kernel state, not a variant discriminator. |
| `Kernel.Error` (code + Optional context) | `context` is optional diagnostic aid, not variant-specific. |
| `Kernel.Directory.Entry` (Optional inode + Optional kind) | Optional fields are platform-specific (POSIX provides; Windows synthesizes), not discriminator-driven. |
| `Kernel.Thread.Affinity` (kind: Kind) | Already delegates to enum `Kind`; no variant-specific extra fields on the struct. |

### swift-io rejections

| Type | Reason for rejection |
|------|---------------------|
| `IO.Completion.Entry` | Already collapsed in `swift-io@3d086ba9` — the validating refactor's third commit. |
| `IO.Event.Actor.Registration.Senders` | Three parallel always-live arrays (`read`, `write`, `priority`); routing is by passed `interest` parameter, not by a stored discriminator. Broadcast-and-drain pattern. Correct as-is. |
| `IO.Completion.Actor.CancelCoordinator` | Reference type required for capture in `@Sendable onCancel` closures. Three orthogonal state bits, not variant-specific. |
| `IO.Completion.Cancellation` | Class wrapping `Atomic<Bool>` — Atomic is `~Copyable` and cannot be embedded in shared value types. Reference type is structurally required, not stylistic. |
| `IO.Event.Actor.Registration` | Two always-meaningful fields (interest + senders). |
| `IO.Blocking.Options` (single Optional `workers: Kernel.Thread.Count?`) | Configuration with absent-default, not discriminator. |
| `IO.Event.Error`, `IO.Error` | Already well-designed enums. |
| Handle types (`IO.Event.Actor.Handle`, `IO.Completion.Actor.Handle`) | Weak back-references for init-cycle break per `[IMPL-083]`. Class shape essential. |

### swift-kernel L3 / L2 standards / swift-foundations sweep

- **swift-kernel L3** (`swift-foundations/swift-kernel/Sources/`): zero `public struct` declarations top-level. All implementation is via extensions on L1 types. Nothing to refactor.
- **L2 standards** (`swift-iso-9945`, `swift-darwin-standard`, `swift-linux-standard`, `swift-windows-standard`): spec-faithful by design. C-ABI types (kevent filter, OVERLAPPED, sockaddr) are deliberately bespoke per `[PLAT-ARCH-005a]` (no platform C types in public API beyond ecosystem wrappers). Out of scope.
- **swift-primitives non-kernel**: define ecosystem types rather than consuming them. Nothing to refactor.
- **swift-foundations L3** (swift-file-system, swift-clocks, etc.): clean. Use enum-based configuration and ecosystem types correctly. Nothing to refactor.

## Cross-Cutting Observations

### Result reshape is the last quadrant of the Submission/Event matrix

The Submission.Opcode reshape collapsed Submission's variant-specific fields
into the opcode enum. The natural partner is the **Event** side — and B1
(Event.Result) is exactly that. Submission has typed opcode (✓); Event has
typed result discrimination (proposed). Sequencing B1 alongside any further
Event work amortizes the L3 adapter touch on `Kernel.Completion+IOUring.swift`
which both refactors would visit.

### What is NOT a candidate axis

- **OptionSet → enum**: per `io-uring-semantic-flag-modeling.md`, this
  conversion is appropriate only when the flags are **mutually exclusive**.
  All remaining OptionSets in the workspace (Submission.Flags, Event.Flags,
  Interest, Permissions, Event.Options) are genuinely combinable and
  correctly OptionSet.
- **Tagged → bespoke struct**: never. The ecosystem direction is *toward*
  Tagged, not away. The 20+ existing Tagged typealiases in
  `swift-kernel-primitives` are the target shape.
- **Class → struct for Sendable wrappers**: the swift-io class wrappers
  (Cancellation, Handle, CancelCoordinator) have structural reasons (atomic
  embedding, weak back-references, closure capture). Not refactor candidates.

### Sibling-pattern check (preventive)

The Submission.Opcode session caught a sibling-pattern inconsistency
(IO.Event.Actor.makeTick vs IO.Completion.Actor's Outcome extension init),
addressed in `swift-io@c443ceca`. No further sibling-pattern asymmetries
surfaced in this inventory pass.

## Recommended Sequencing (Advisory)

The handoff explicitly defers execution decisions to the user / supervisor,
but a suggested ordering for prioritization:

| Order | Item | Justification |
|-------|------|---------------|
| 1 | B1 (Completion.Event.Result) | Natural partner to the Submission.Opcode reshape — closes the Submission/Event symmetry. Touches the same L3 adapter file (`Kernel.Completion+IOUring.swift`); doing it now means one careful import audit instead of two (avoids the silent-import regression noted in the prior reflection). |
| — | A1 / A2 (Inode / Device) | RETRACTED — see retraction notes above. Bespoke shape is correct. |
| — | A3 (TTY.Size → Coordinate) | DEFERRED until coordinate-adoption guidance for non-spatial dimensions exists. |
| — | A4 / B2 (Time.Deadline) | DEFERRED to swift-clock-primitives `clock-time-unification.md` resolution. Do not pre-empt. |

## What This Inventory Did Not Cover

- **Performance-driven refactors** — this pass is purely about ecosystem-type
  adoption and discriminated-union shape. Performance tuning of any of these
  surfaces is out of scope.
- **Naming audits** — `[API-NAME-001]` / `[API-NAME-002]` compliance is
  separately tracked in the `Audits/` reports.
- **Cross-package extraction** — moving types between packages (L1→L2, L3→L1)
  is `architecture-refactor.md` territory, not this inventory's.
- **Macro-driven rewrites** — `@CoW`, `@Defunctionalize`, `@Witness` adoption
  decisions are independent.

## Status & Next Steps

- This document is **RECOMMENDATION** status. No code changes have been made.
- A follow-up session should select from the candidates above with explicit
  user authorization before executing.
- The pre-existing uncommitted change in `Research/_index.md` (out-of-scope
  per the handoff's working-tree-respect constraint) means this document is
  **not yet linked from the index**. The link entry to add when the index is
  next touched:
  `| [ecosystem-refactor-opportunities](ecosystem-refactor-opportunities.md) | Workspace inventory of ecosystem-type adoption + enum-with-associated-values refactor candidates beyond the Submission.Opcode reshape | 2026-04-17 | RECOMMENDATION |`
