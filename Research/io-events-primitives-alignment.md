# IO Events Primitives Alignment Audit

<!--
---
version: 1.0.0
last_updated: 2026-02-24
status: SUPERSEDED
tier: 2
---
-->

> **Superseded 2026-03-26**: Subsumed by `data-structure-ecosystem-triage.md` (2026-03-23) which covers all 6 swift-io targets, not just IO Events.

## Context

swift-io was built top-down as a Layer 3 (Foundations) package. Its dependencies — the Layer 1 primitives — were subsequently refactored bottom-up into typed data structure primitives. A mechanical compilation fix aligned Tagged initializers (2026-02-24), but the module still uses stdlib data structures where typed primitives now exist.

This audit inventories every data structure in the IO Events module and evaluates each against the available primitives ecosystem: Array, List, Stack, Queue, Hash.Table, Set, Dictionary, Heap, Tree, Slab, Bitset, Bit.Vector, and Buffer.

## Question

Which data structures in the IO Events module should be replaced by upstream primitives, and in what priority order?

## Inventory

### Current Data Structures

| Location | Type | Operations | Semantic Role |
|----------|------|------------|---------------|
| `Selector.registrations` | `[ID: Registration]` (Swift.Dictionary) | insert, lookup, remove, iterate keys | ID → registration map |
| `Selector.waiters` | `[Permit.Key: Waiter]` (Swift.Dictionary) | insert, lookup, remove, filter-iterate | key → waiter map |
| `Selector.permits` | `[Permit.Key: IO.Event.Flags]` (Swift.Dictionary) | insert, lookup-remove, remove | key → flags map |
| `Selector.deadlineGeneration` | `[Permit.Key: UInt64]` (Swift.Dictionary) | insert, lookup, remove, default-subscript | key → generation counter |
| `Selector.pendingReplies` | `[Reply.ID: CheckedContinuation<...>]` (Swift.Dictionary) | insert, lookup-remove, iterate-drain | reply correlation map |
| `Selector.deadlineHeap` | `Heap<DeadlineScheduling.Entry>` | push, peek, take | min-heap (already primitives) |
| `Registration.Queue` | `Ownership.Mutable<Mutex<Deque<T>>>.Unchecked` | enqueue, dequeue, drain | MPSC FIFO queue |
| `Registry.shared` | `Mutex<[Int32: [ID: Entry]]>` | nested dictionary CRUD | cross-thread registration lookup |
| Poll event buffer | `[IO.Event]` / `[Kernel.Kqueue.Event]` (Swift.Array) | init-repeating, prefix, index | fixed-size reusable buffer |
| Poll stale filter | `Set<IO.Event.ID>` (Swift.Set) | init-from-keys, contains | ephemeral membership test |

### Already Using Primitives

| Structure | Primitive | Status |
|-----------|-----------|--------|
| `deadlineHeap` | `Heap<DeadlineScheduling.Entry>` from `Heap_Primitive` | Correct |
| `Registration.Queue` inner | `Deque<T>` from `Buffer_Primitives` | Semantic mismatch (see F-1) |

## Analysis

### F-1: Registration.Queue — Deque used as Queue

**Priority**: High
**Current**: `Deque<T>` from `Buffer_Primitives` with `back.push` / `front.take`
**Proposed**: `Queue<T>` from `Queue_Primitives`

The `Deque` (double-ended queue) is used exclusively as a single-ended FIFO:
- Enqueue: `deque.back.push(element)` — only back
- Dequeue: `deque.front.take` — only front
- Never uses `back.take` or `front.push`

`Queue<T>` from queue-primitives is the exact semantic type. Using it:
1. Declares FIFO intent at the type level per [IMPL-INTENT]
2. Prevents accidental double-ended access (Deque exposes both ends)
3. Aligns the dependency: `Queue_Primitives` instead of raw `Buffer_Primitives`

**Additional fix**: The `drain()` method at `IO.Event.Registration.Queue.swift:29` contains:
```swift
elements.reserveCapacity(Int(bitPattern: deque.count.rawValue.rawValue))
```
This `.rawValue.rawValue` chain violates [IMPL-002]. With `Queue<T>`, the count type may offer a typed integration overload per [INFRA-002], or at minimum the API surface would be `queue.count` rather than `deque.count.rawValue.rawValue`.

**Impact**: Import change (`Queue_Primitives` replaces `Buffer_Primitives`), Registration.Queue typealias change, and 3 method bodies updated. No public API change.

---

### F-2: Slab for ID-Keyed Registrations

**Priority**: Investigate
**Current**: `[IO.Event.ID: Registration]` (Swift.Dictionary, hash-based)
**Candidate**: `Slab<Registration>` from `Slab_Primitives`

`IO.Event.ID` is internally generated via `Atomic<UInt64>.wrappingAdd`. It serves purely as a lookup key — no semantic ordering, no external assignment. A `Slab` provides:
- O(1) guaranteed insert/remove/lookup (no hashing, no amortization)
- Bitmap-tracked occupancy
- Dense storage

**Risk — ABA problem**: Slab reuses indices after removal. A stale kqueue/epoll event carrying a recycled ID could match a *different* registration. The current monotonic-counter scheme avoids this because IDs are never reused.

**Mitigation options**:
1. **Generation counter per slot**: Each slot carries a generation. The event ID becomes `(slabIndex, generation)`. Stale events have mismatched generation. This is exactly the pattern already used for `deadlineGeneration`.
2. **Accept monotonic IDs**: Keep the counter scheme but store registrations in a Slab indexed by `id % capacity`, with overflow handling. Adds complexity without clear benefit.
3. **Defer**: The stdlib Dictionary works correctly. The Slab optimization is meaningful only under high registration churn.

**Recommendation**: Investigate option 1 (generation-tagged slab indices) as a follow-up. The pattern already exists in the codebase for deadline entries. If adopted, it would also eliminate the per-poll `Set<IO.Event.ID>` construction (F-6).

---

### F-3: Global Registry — Structural Duplication

**Priority**: Investigate
**Current**: `Mutex<[Int32: [IO.Event.ID: IO.Event.Registration.Entry]]>` — process-global, shared between Selector actor and poll thread
**Also**: `Selector.registrations: [ID: Registration]` — actor-isolated, per-Selector

The global registry duplicates the per-Selector registration map. Both store `(id → descriptor, interest)` mappings. The global registry exists because the poll thread needs to:
1. Validate events (filter stale IDs)
2. Look up descriptors for kernel operations

This duplication is an architectural concern, not a data-structure concern. Replacing the nested `Dictionary` with a different collection doesn't address the root issue: two copies of the same data exist for thread-isolation reasons.

**Possible resolution**: If the poll thread validation were restructured (e.g., the Selector sends a snapshot of valid IDs to the poll thread via the Registration.Queue, or uses a shared concurrent-read structure), the global registry could be eliminated entirely.

**Recommendation**: Flag for architectural review. Not a primitives-alignment issue.

---

### F-4: Swift.Dictionary → Dictionary.Ordered

**Priority**: Low
**Current**: 5 stdlib `Dictionary` instances in Selector (registrations, waiters, permits, deadlineGeneration, pendingReplies)
**Candidate**: `Dictionary.Ordered` from `Dictionary_Primitives`

**Evaluation**:

| Criterion | Swift.Dictionary | Dictionary.Ordered |
|-----------|-----------------|-------------------|
| Lookup | O(1) amortized | O(1) amortized |
| Insert | O(1) amortized | O(1) amortized |
| Remove | O(1) amortized | O(n) — shifts to preserve order |
| Ordering | Unordered | Insertion-ordered |
| Key constraint | `Hashable` | `Hash.Protocol` |
| Foundation-free | Yes (stdlib) | Yes |

**Against**:
- None of the 5 dictionaries need insertion ordering. Dictionary.Ordered preserves insertion order — a feature the Selector never uses
- Dictionary.Ordered has **O(n) removal**: `Buffer.Linear.remove(at:)` shifts all subsequent elements via `moveInitialize`, and the hash table scans all buckets to decrement stored positions (`decrementAllPositions(after:)` iterates every bucket). Stdlib Dictionary has **O(1) amortized removal** (tombstone the bucket, no shifting). The Selector calls `waiters.removeValue(forKey:)` in `processEvent()`, `drainCancelledWaiters()`, and `drainExpiredDeadlines()` — potentially multiple times per event batch. Each O(n) removal compounds: k removals per batch costs O(k * n), degrading event loop throughput as waiter count grows
- Migration requires `Hash.Protocol` conformance on `IO.Event.ID`, `Permit.Key`, and `Reply.ID` — protocol adoption cost for no functional gain
- The stdlib Dictionary is not an ad-hoc implementation; it's a well-optimized hash table

**Recommendation**: Do not migrate. The Selector's use case is unordered maps with frequent removal — exactly where stdlib Dictionary's O(1) amortized removal dominates. Dictionary.Ordered is designed for ordered key-value storage where removal is infrequent relative to iteration, which is not the pattern here.

**Escalated**: The removal complexity question has been escalated to a primitives-level research document: [dictionary-removal-strategies](../../../swift-primitives/swift-dictionary-primitives/Research/dictionary-removal-strategies.md). That document evaluates swap-remove, slab-backed, and linked-backed strategies for providing O(1) removal in the primitives ecosystem.

---

### F-5: Event Buffer — Array → Array.Fixed

**Priority**: Low
**Current**: `[IO.Event](repeating:count: maxEvents)` — pre-allocated, reused across poll iterations
**Candidate**: `Array.Fixed` from `Array_Primitives`

The event buffer size is determined at runtime by `driver.capabilities.maxEvents` and never changes. `Array.Fixed` would express the fixed-size intent. However:
- The buffer is purely internal to the poll loop
- The stdlib Array with pre-allocation performs identically
- No type-safety benefit (the elements are `IO.Event`, not phantom-typed)

**Recommendation**: Optional. Low-priority semantic improvement. Not blocking.

---

### F-6: Per-Poll Set Construction

**Priority**: Low (depends on F-2)
**Current**: Each `poll()` call constructs `Set<IO.Event.ID>` from registry dictionary keys to filter stale events
**Impact**: O(n) per poll iteration where n = number of registrations

If F-2 (Slab for registrations) is adopted, this becomes `slab.contains(id)` — O(1) per event, no set construction. Without F-2, the set construction is the correct approach given the current dictionary-based registry.

**Recommendation**: Defer until F-2 is resolved.

---

### F-7: drain() rawValue Chain

**Priority**: Code fix (independent of other findings)
**Location**: `IO.Event.Registration.Queue.swift:29`
**Current**:
```swift
elements.reserveCapacity(Int(bitPattern: deque.count.rawValue.rawValue))
```
**Violation**: [IMPL-002] — `.rawValue.rawValue` chain at call site

This should use a typed integration overload. Per [INFRA-002], `Int.init(bitPattern: Cardinal)` exists. The fix depends on whether `Deque.count` returns `Cardinal` or `Tagged<_, Cardinal>`:

```swift
// If count is Cardinal:
elements.reserveCapacity(Int(bitPattern: deque.count))
// If count is Tagged<_, Cardinal>:
elements.reserveCapacity(Int(bitPattern: deque.count.rawValue))
```

**Recommendation**: Fix immediately. Single-line change, no architectural implications.

## Outcome

**Status**: SUPERSEDED

### Priority Order

| Priority | Finding | Action | Effort |
|----------|---------|--------|--------|
| 1 | F-1: Queue for Registration.Queue | Replace Deque with Queue | Small (import + typealias + 3 methods) |
| 2 | F-7: drain() rawValue chain | Fix [IMPL-002] violation | Trivial (1 line) |
| 3 | F-2: Slab for registrations | Investigate generation-tagged slab indices | Medium (design + implement) |
| 4 | F-3: Global registry duplication | Architectural review | Large (cross-cutting) |
| 5 | F-5: Array.Fixed for event buffer | Optional semantic improvement | Small |
| 6 | F-4: Dictionary.Ordered | Do not migrate | — |
| 7 | F-6: Per-poll Set | Deferred to F-2 | — |

### Key Insight

The IO Events module is architecturally sound. The Heap is already from primitives. The remaining stdlib collections (Dictionary, Array, Set) are mostly correct choices for their use cases. The highest-value opportunity is F-1 (Queue), which is a semantic-intent improvement — using the right type for the right job — rather than a performance concern.

The Slab opportunity (F-2) is the most architecturally interesting finding but requires careful ABA analysis before adoption. The generation-counter pattern already exists in the codebase (`deadlineGeneration`), providing a proven mitigation path.

## References

- [IMPL-INTENT] — Code reads as intent, not mechanism
- [IMPL-002] — Write the math, not the mechanism (no `.rawValue` chains)
- [INFRA-002] — Cardinal integration overloads
- [INFRA-107] — Sequence iteration infrastructure
- swift-queue-primitives — Queue<T> FIFO type
- swift-slab-primitives — Slab<T> slot allocator
