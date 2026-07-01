---
title: Canonical Swift Idiom for Sendable Heap References With Scoped Lifetimes
version: 0.1.0
status: IN_PROGRESS
tier: 2
created: 2026-04-16
last_updated: 2026-04-16
applies_to:
  - swift-io
  - swift-sockets
---

# Context

The deferred actor-state-visibility fix in swift-io surfaced a recurring
design wall: `IO.Scope.selector` is freely `Sendable` (struct holding
two heap references — `Loop` class + `Runtime` actor), so callers can
extract it and use it *after* `await scope.close()`. The `Scope` is
`~Copyable, ~Escapable`, but `~Escapable` does not compose with
`Sendable`, so the structural annotation is lying. The L1/L2/L3 fix
discussion hit the same wall. Without a canonical answer, every
"scoped-lifetime heap reference" question in swift-io re-derives the
same design space.

# Question

What is the canonical Swift idiom for "this reference cannot be used
after that scope ends" when the type is a class (heap reference) and
must be `Sendable`? Three candidate answers have been sketched but not
fully evaluated:

1. **Make the class non-Sendable**, pass a `~Copyable, ~Escapable` view
   that wraps the class for the duration of the scope.
2. **Generation counter / lifetime token** — the class remains
   Sendable, but each operation validates a token that is invalidated
   on scope close.
3. **Closure-scoped public API only** — no extractable scope; the user
   cannot hold a reference that outlives the closure body.

Each answer has different ergonomic, performance, and safety
characteristics. The decision likely generalizes to other swift-io
types (`IO.Event.Channel`, `IO.Completion.Queue`, `IO.Runtime`).

# Prior Work

- `swift-foundations/swift-io/Research/actor-state-visibility-structural-fix.md` — Option D slip pattern (rejected)
- `swift-foundations/swift-io/Research/audit.md` — five audit findings DEFERRED pending structural fix
- `feedback_structural_fix_preference.md` — leverage language/type system to make issues structurally impossible
- Source reflection: `Research/Reflections/2026-04-08-actor-state-fix-deferred-structural-vs-runtime.md`

# Analysis

_Stub — to be filled in during investigation._

Key sub-questions to work through:

- Does Swift have any native expression for "T: Sendable but with
  narrower lifetime than its heap lifetime"?
- How do NIO/Tokio/Rust libraries express this invariant?
- What's the ergonomic cost of closure-scoped APIs vs extraction?
- Can `~Escapable` views over a Sendable backing store compose cleanly
  in Swift 6.3+?

# Outcome

_Placeholder — to be filled when analysis completes._

# Provenance

Source: `swift-foundations/swift-io/Research/Reflections/2026-04-08-actor-state-fix-deferred-structural-vs-runtime.md` action item.
