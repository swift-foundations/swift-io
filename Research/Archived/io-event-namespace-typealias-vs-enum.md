# IO.Event Namespace: Typealias vs Enum

<!--
---
version: 1.0.0
last_updated: 2026-04-01
status: DECISION
---
-->

## Context

During the code-surface audit remediation (Phase 5b), `IO.Event = Kernel.Event` was converted from a typealias to a proper namespace enum per [API-NAME-004]. This broke 65+ files and required adding forwarding typealiases for `Interest`, `Flags`, `ID` and a manual `Queue` namespace. The conversion raises a fundamental question about how IO.Event should relate to Kernel.Event.

## Question

Should `IO.Event` be a typealias to `Kernel.Event` (namespace adoption) or a proper namespace enum with explicit forwarding?

## Analysis

### Factual basis

- `Kernel.Event` is a **struct** with nested types: `Interest` (OptionSet), `Flags` (OptionSet), `ID` (Tagged), `Queue` (Darwin-only kqueue namespace)
- IO Events module adds **52+ types** via `extension IO.Event { }`: Channel, Selector, Driver, Token, Poll, etc.
- `Kernel.Event.Interest` is used as a value type in **14+ files** across IO Events
- `Kernel.Event.ID` is used as a value type in **10+ files**
- `Kernel.Event` itself (the struct) is used as a value in **~2 files** (Buffer.Pool, poll loops)

### Option A: Typealias (`IO.Event = Kernel.Event`)

`IO.Event` IS `Kernel.Event`. All nested types flow through naturally.

**Pros:**
- `IO.Event.Interest`, `IO.Event.ID`, `IO.Event.Flags` work with zero forwarding
- `IO.Event.Queue` (kqueue namespace) works naturally
- Zero boilerplate — no forwarding typealiases, no manual namespaces
- Conceptually coherent: "IO Events are Kernel Events with async coordination added"
- 52 extensions on `IO.Event` genuinely extend the kernel event concept with IO behavior

**Cons:**
- `extension IO.Event { enum Channel {} }` actually nests Channel inside `Kernel.Event` — visible as `Kernel.Event.Channel` from downstream code
- `IO.Event` as a value type IS `Kernel.Event` — `let event: IO.Event` is a kernel-level struct, not an IO abstraction
- Violates [API-NAME-004] strict reading — it IS a typealias bridge
- Changes to `Kernel.Event`'s nested types (new cases, renamed members) automatically propagate to IO.Event's surface

### Option B: Namespace enum with forwarding typealiases

`IO.Event` is an independent enum. Interest/Flags/ID forwarded via typealiases.

**Pros:**
- Clean namespace separation — IO types don't pollute `Kernel.Event`
- `IO.Event.Interest` still works ergonomically
- IO.Event is a proper type boundary — downstream code sees only IO concepts

**Cons:**
- Still uses typealiases (3 forwarding + 1 for Queue)
- Requires manual `Queue` namespace for kqueue operations
- Typealiases ARE [API-NAME-004] violations — forwarding is still aliasing
- Build broke when converting (parsing ambiguity with `[Kernel.Event]`, error type inference)

### Option C: Namespace enum, full Kernel.Event.* names everywhere

`IO.Event` is an enum. No typealiases. All value-type references use `Kernel.Event.Interest`, etc.

**Pros:**
- Strictest compliance — zero typealiases
- Clear provenance: `Kernel.Event.Interest` shows exactly where the type lives
- IO.Event namespace is purely IO concepts

**Cons:**
- 24+ files need `Kernel.Event.Interest` instead of `IO.Event.Interest`
- Breaks layered abstraction: IO module code references Kernel types directly, mixing abstraction levels in signatures like `func register(_: Kernel.Descriptor, interest: Kernel.Event.Interest) -> IO.Event.Register.Result`
- `Kernel.Event.Queue` for kqueue operations leaks the platform layer into IO module code

### Comparison

| Criterion | A: Typealias | B: Enum + forwarding | C: Enum + full names |
|-----------|-------------|---------------------|---------------------|
| [API-NAME-004] compliance | No (typealias) | No (3 typealiases) | Yes |
| Zero boilerplate | Yes | No (4 forwards) | Yes |
| Namespace separation | No (IO types on Kernel.Event) | Yes | Yes |
| Ergonomics at call site | `IO.Event.Interest` | `IO.Event.Interest` | `Kernel.Event.Interest` |
| Layered abstraction preserved | Partially (mixed identity) | Yes | No (Kernel leaks into IO) |
| Build stability | Proven (original design) | Fragile (ambiguities) | Unknown |
| Maintenance cost | Zero | Low (forward sync) | Low (no sync needed) |

### Key distinction: namespace adoption vs rename bridge

The removed typealiases (Deadline, Pool, Lane.Count) were **rename bridges** — they simply gave shorter names to types from other modules. `IO.Event = Kernel.Event` is different: it's **namespace adoption**, where an entire type hierarchy is adopted into a new namespace. The 52 extensions aren't renaming; they're building a coherent domain on top of the kernel type.

However, this distinction is not recognized by [API-NAME-004] as written. The rule says typealiases for type unification are forbidden, period.

## Outcome

**Status**: DECISION — Option A chosen (2026-04-01).

**Rationale**: The typealias is architecturally foundational — it's not a convenience rename but a namespace adoption pattern. IO.Event IS the kernel event extended with async coordination. The 52 nested types express this relationship. Options B and C both introduce friction (forwarding or mixed abstraction levels) to enforce a rule designed for rename bridges, not namespace adoption.

If Option A is chosen, the convention should distinguish namespace adoption typealiases from rename bridges:
- **Namespace adoption** (`IO.Event = Kernel.Event`): The aliasing type extends the aliased type's concept with domain-specific behavior. Permitted.
- **Rename bridge** (`IO.Deadline = Clock.Suspending.Instant`): The aliasing type simply renames for convenience. Forbidden per [API-NAME-004].

## References

- Code-surface audit: `swift-io/Research/audit.md` — Finding #7
- Plan: `.claude/plans/soft-gliding-blanket.md` — Phase 5b
