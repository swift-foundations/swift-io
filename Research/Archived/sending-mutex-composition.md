# Research: Mutex.withLock `sending` vs Ecosystem Type Composition

> **Status**: Both sites resolved. Site 1: `push(_:to:)`. Site 2: flipped nesting (withRebound inside withLock).
> **Date**: 2026-04-03
> **Toolchain**: Apple Swift 6.3 (swiftlang-6.3.0.123.5)
> **Scope**: Why Property.View coroutine accessors and rebound pointer captures
> do not compose with `Mutex.withLock`'s `(inout sending State)` parameter.

---

## [RES-SEND-001] Observation: Two Incompatible Sites

Two sites in swift-io required workarounds to operate inside `Mutex.withLock`:

**Site 1 -- Deque mutation via Property.View** — **RESOLVED**

Originally used a `nonisolated(unsafe)` workaround to bypass the coroutine
accessor. Now uses `deque.push(element, to: .back)` directly
(`IO.Event.Registration.Queue.swift:44`), bypassing the Property.View coroutine
entirely. No unsafe, no workaround.

**Site 2 -- Rebound pointer capture** (`IO.Event.Queue.Operations.swift`) — **RESOLVED**:

```swift
handle.buffer.withRebound(to: Kernel.Kqueue.Event.self) { rawEvents in
    var rawCopy: [Kernel.Kqueue.Event] = []   // workaround: heap alloc per poll
    // ... copy rawEvents into rawCopy ...
    IO.Event.Registry.shared.withLock { outer in
        // Uses rawCopy (Sendable Array) instead of rawEvents (closure parameter)
    }
}
```

Without the copy, capturing `rawEvents` into the `withLock` closure merges the
`withRebound` closure's region with the `inout sending` parameter, tainting it.

**Resolution**: Flipped the nesting — `withRebound` inside `withLock` instead of
around it. The buffer memory retains polled data between `withRebound` calls, so
the poll and conversion are split into two sequential rebounds. No cross-scope
capture, no heap allocation.

---

## [RES-SEND-002] Analysis: The `sending` Region Isolation Model

### Mutex.withLock Signature

The standard library provides two overloads (SDK `Synchronization.swiftinterface`):

```swift
// Overload 1: sending (preferred when $SendingArgsAndResults is available)
func withLock<Result, E>(
    _ body: (inout sending Value) throws(E) -> sending Result
) throws(E) -> sending Result

// Overload 2: non-sending (fallback)
func withLock<Result, E>(
    _ body: (inout Value) throws(E) -> Result
) throws(E) -> Result
```

With Swift 6's `$SendingArgsAndResults` feature flag enabled (which it is for all
current toolchains), overload 1 is always selected. The `inout sending` parameter
creates a separate isolation region for the mutex's state.

### SE-0430 `sending` Semantics

Per [SE-0430](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0430-transferring-parameters-and-results.md):

- A `sending` parameter must be in a **disconnected region** at the call site.
- An `inout sending` parameter must be disconnected both on entry AND on exit.
- Inside the closure, the parameter value can be merged with other regions, but
  must be reassigned to a disconnected value before the closure returns.
- If a non-Sendable value from the caller's region merges into the `sending`
  parameter's region, the parameter becomes **task-isolated**, violating the exit
  constraint.

### SE-0414 Region Merging Rules

Per [SE-0414](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md):

- **Property access**: Accessing a non-Sendable property produces a result in the
  **same region** as the source value (modeled as a function call with `self`).
- **Function calls**: All non-Sendable arguments are merged into one region.
- **Closure capture**: Capturing a value from an outer scope merges the captured
  value's region with whatever regions the closure body touches.

---

## [RES-SEND-003] Analysis: Site 1 -- Why `deque.back.push(element)` Fails

### The Accessor Chain

The expression `deque.back.push(element)` involves three steps:

1. **`deque.back`** -- accesses a computed property via `mutating _read`:
   ```swift
   public var back: Back.View {
       mutating _read {
           yield unsafe .init(&self)  // UnsafeMutablePointer to self
       }
   }
   ```
   Because `.push()` is a non-mutating `func` on the view, the compiler selects
   `_read` (not `_modify`). The `_read` accessor is nonetheless `mutating` on
   the deque because it needs `&self` to construct the pointer. It yields a
   `Property.View.Typed` wrapping an `UnsafeMutablePointer<Deque>`.
   The yielded view is in the same region as `deque`.

2. **The view** is `Property<Back, Deque>.View.Typed<Element>`, which is:
   ```swift
   public struct Typed<Element: ~Copyable>: ~Copyable, ~Escapable {
       internal let _base: UnsafeMutablePointer<Base>
   }
   ```
   It is `~Copyable` and `~Escapable`. It holds a raw pointer to the deque.

3. **`.push(element)`** on the view:
   ```swift
   public func push(_ element: consuming Element) {
       unsafe base.pointee._buffer.push.back(consume element)
   }
   ```
   This takes `element` from the caller and writes it through the pointer into the
   deque's buffer.

### The Region Conflict

The region checker sees the following:

- `deque` is in the **sending region** (from `inout sending`).
- `deque.back` yields a view that is in the **same region as `deque`** (property
  access rule from SE-0414).
- `.push(element)` is a function call where:
  - `self` (the view) is in the sending region.
  - `element` comes from the **caller's region** (even if `element` is Sendable,
    the region checker may not see through the coroutine boundary to determine this).

The coroutine accessor (`_read` in this case, though `_modify` has the same
issue) is the critical barrier. The region isolation checker treats the coroutine
as an opaque function boundary. It cannot verify that:

1. The yielded `Property.View.Typed` value's pointer access is safe within the
   `sending` region.
2. Methods called on the yielded value do not leak the `sending` region.
3. The coroutine's suspend/resume points maintain region disconnection.

**Root cause**: The coroutine accessor creates a yield point that the
region-based isolation checker cannot see through. The checker conservatively
treats the yielded value and any operations on it as potentially merging the
`sending` region with the caller's task-isolated region.

### Why `deque.front.take` Works But `deque.back.push(element)` Does Not

Both expressions use the same accessor type (`_read`) — `.take` is a computed
property getter and `.push()` is a non-mutating `func`, so neither requires
`_modify`. The accessor type is not the distinguishing factor.

The distinction is **value flow direction**:

- `deque.front.take` — no external values cross INTO the sending region. The
  returned `Element?` flows OUT as the closure's `sending Result`. The region
  checker only needs to verify the result is disconnected on exit.
- `deque.back.push(element)` — `element` flows IN from the caller's capture
  region through the coroutine-yielded view into the sending region. The checker
  cannot verify through the coroutine boundary that this does not taint the
  `sending` region with the caller's task-isolated region.

### Note on Sendability

Even though `Element: Sendable` in the `enqueue` function, the region checker
operates on regions, not on Sendable conformance alone. A Sendable value starts
in a disconnected region, but the act of passing it through a coroutine boundary
into the `sending` parameter's region is what the checker rejects -- it cannot
prove that the coroutine's pointer indirection maintains the region invariants.

---

## [RES-SEND-004] Analysis: Site 2 -- Rebound Pointer Region Tainting

### The Mechanism

```swift
handle.buffer.withRebound(to: Kernel.Kqueue.Event.self) { rawEvents in
    IO.Event.Registry.shared.withLock { outer in
        // Using rawEvents here FAILS
        for i in 0..<count { ... rawEvents[i] ... }
    }
}
```

Despite `UnsafeMutableBufferPointer` being conditionally `Sendable` (conformance
requires `Element: Sendable`, which `Kernel.Kqueue.Event` satisfies), the region
checker rejects this.

### Why: Closure Capture Region Merging

The `withLock` closure captures `rawEvents` from the enclosing `withRebound`
closure. Per SE-0414's closure capture rule:

- `rawEvents` is a parameter of the `withRebound` closure -- it lives in that
  closure's local region.
- The `withLock` closure captures `rawEvents` by value. However, the region
  checker merges the captured value's region (the `withRebound` closure's region)
  with the `withLock` closure's region.
- Inside `withLock`, the closure body has access to `outer` (the `inout sending`
  parameter). Any non-trivial region merging with `outer` taints it.
- The capture of `rawEvents` from the outer closure introduces a region dependency
  between the `withRebound` scope and the `withLock` scope. The checker
  conservatively treats this as the `inout sending` parameter becoming
  task-isolated.

### Why This Is A Fundamental Region Constraint (Not a Bug)

The region checker's conservatism here is defensible: `rawEvents` points into
`handle.buffer`'s memory, which is borrowed for the duration of `withRebound`.
If the `withLock` closure could escape (the checker must assume non-`@Sendable`
closures can), capturing `rawEvents` would create a dangling pointer risk. The
`sending` annotation's purpose is precisely to prevent such cross-region aliasing.

The fact that `withLock`'s closure is `@Sendable`-like (it must be, for the
`sending` semantics to work) means the checker enforces that everything captured
into it is safely transferable. A buffer pointer borrowed from an outer scope is
not safely transferable, even if its type is `Sendable`.

### The Workaround Cost

The current workaround copies raw events into a `[Kernel.Kqueue.Event]` array,
which is:
- A heap allocation per poll cycle (via `reserveCapacity`)
- O(n) element copies for `n` events
- On the hot path of the kqueue event loop

For typical poll counts (tens of events), this is measurable but not catastrophic.
For high-frequency polling with many events, it adds allocation pressure.

---

## [RES-SEND-005] Analysis: Compiler Limitation vs Working-As-Intended

### Summary of Findings

| Aspect | Assessment |
|--------|------------|
| `inout sending` semantics | Working as designed per SE-0430 |
| Region merging on property access | Working as designed per SE-0414 |
| Coroutine accessor opacity | **Compiler limitation** |
| Closure capture region merging | Working as designed, conservative |
| Non-sending overload availability | Exists but never selected |

### The Core Limitation

The `_modify`/`_read` coroutine accessors are opaque to the region isolation
checker. The checker cannot reason about:

1. What the coroutine does with its `&self` parameter during the yield.
2. Whether the yielded value's operations maintain region disconnection.
3. Whether the coroutine's resume path re-establishes region invariants.

This is not explicitly addressed in SE-0414 or SE-0430. The proposals describe
region merging for function calls and property accesses, but coroutine accessors
are a hybrid: they are property accesses that behave like function calls with
suspend points.

The new SE-0474 yielding accessors (`yielding borrow`, `yielding mutate`) use a
different ABI and implementation path, but they do not appear to address the
region isolation interaction either. The proposals are silent on `sending`
compatibility.

### Swift Forum Confirmation

Multiple Swift forum threads confirm that `inout sending` has known composition
limitations:

- [Cannot forward `inout sending` to another function](https://github.com/swiftlang/swift/issues/82553)
- [`inout sending` parameter cannot be task-isolated at end of function](https://forums.swift.org/t/inout-sending-parameter-cannot-be-task-isolated-at-end-of-function/80144)
- [Can not assign a non-sendable but sending value into inout sending value](https://github.com/swiftlang/swift/issues/77199)

Michael Gottesman (Swift team) acknowledged in [the Mutex forum thread](https://forums.swift.org/t/sending-inout-sending-mutex/76373)
that the region checker has known gaps around `inout sending`, and that some
restrictions are overzealous while others are bugs being fixed.

---

## [RES-SEND-006] Options

### Option A: Use `push(_:to:)` Instead of `.back.push()` (Site 1 Only)

Bypass the Property.View coroutine entirely by using the direct method:

```swift
mutable.value.withLock { deque in
    deque.push(element, to: .back)
}
```

**Assessment**: `Deque.push(_:to:)` is a `mutating func` that takes the element
and position directly. No coroutine accessor, no yielded view, no pointer
indirection. The region checker can see that a Sendable element is being passed
to a mutating method on the `inout sending` parameter -- this should work.

- **Pro**: Zero overhead, zero unsafe, idiomatic.
- **Pro**: Already exists -- `Queue.DoubleEnded` has `push(_:to:)` on line 62 and
  line 147 of `Queue.DoubleEnded.swift`.
- **Con**: Loses the `.back.push()` call-site ergonomics.
- **Verdict**: Best option for Site 1. This is what the `~Copyable` enqueue
  overload already does (line 88: `deque.push(element.take()!, to: .back)`).

### Option B: Keep Current Workarounds, Improve Annotations

Leave the `nonisolated(unsafe)` workaround for Site 1 and the Array copy for
Site 2. Improve documentation and tracking annotations.

- **Pro**: Already working, no code changes needed.
- **Con**: `nonisolated(unsafe)` is a correctness escape hatch, not a solution.
- **Con**: Site 2's array copy is a per-poll-cycle allocation on the hot path.
- **Verdict**: Acceptable as interim but should not be the permanent answer.

### Option C: Force Non-Sending Overload Selection

The SDK provides a `(inout Value)` overload alongside `(inout sending Value)`.
If the `sending` overload could be bypassed, the region isolation constraints
disappear.

```swift
// Hypothetical: force non-sending overload
mutex.withLock { (deque: inout Deque<Element>) in
    deque.back.push(element)  // Would work -- no sending constraint
}
```

- **Pro**: Eliminates all region issues.
- **Con**: The non-sending overload requires `Result: Copyable` (no `~Copyable`
  return). More importantly, Swift's overload resolution strongly prefers the
  `sending` variant -- explicit type annotation may not be sufficient to force
  the fallback.
- **Con**: Loses the safety guarantees that `sending` provides.
- **Verdict**: Not viable. The overload selection is controlled by the
  `$SendingArgsAndResults` feature flag, not by call-site annotations.

### Option D: Add `Deque.withBack(_:)` / `Deque.withFront(_:)` Closure Methods

Add closure-based mutation methods that avoid the coroutine accessor:

```swift
extension Deque where Element: ~Copyable {
    mutating func withBack(_ body: (inout Back.View) -> Void) {
        var view: Back.View = unsafe .init(&self)
        body(&view)
    }
}
```

- **Pro**: Avoids coroutine entirely.
- **Con**: Duplicates the Property.View pattern with closures -- goes against the
  design intent of Property.View.
- **Con**: Does not solve the fundamental region issue -- the `body` closure still
  captures from the outer scope.
- **Verdict**: Not recommended. Adds API surface without solving the root cause.

### Option E: Wait for Compiler Improvements

Track the Swift compiler's progress on:
- Region checker improvements for coroutine accessors
- `inout sending` forwarding fixes (swiftlang/swift#82553)
- Potential `sending` annotation on coroutine yields

- **Pro**: The correct long-term solution.
- **Con**: No timeline. These are deep compiler changes.
- **Verdict**: Track but do not block on.

### Option F: Site 2 -- Restructure to Avoid Nested Closures

For the rebound pointer case, restructure to avoid nesting `withLock` inside
`withRebound`:

```swift
// Poll into raw buffer, convert to Array BEFORE the lock
let rawEvents: [Kernel.Kqueue.Event] = handle.buffer.withRebound(...) { raw in
    (0..<count).map { unsafe raw[$0] }
}
// Now rawEvents is a Sendable Array in a disconnected region
let collected = IO.Event.Registry.shared.withLock { outer in
    // ... use rawEvents freely ...
}
```

- **Pro**: Eliminates nested closure capture entirely.
- **Pro**: The Array allocation exists either way (current workaround also allocates).
- **Con**: Still allocates per-poll. Same cost as current workaround.
- **Con**: Splits the control flow into two separate scopes.
- **Verdict**: Marginal improvement over current approach. Same allocation cost
  but cleaner structure.

### Option G: Site 2 -- Use `withUnsafeTemporaryAllocation` for Stack Buffer

Replace the heap-allocated Array with a stack buffer:

```swift
withUnsafeTemporaryAllocation(of: Kernel.Kqueue.Event.self, capacity: count) { temp in
    for i in 0..<count { temp[i] = unsafe rawEvents[i] }
    IO.Event.Registry.shared.withLock { outer in
        // Use temp -- but temp is also a closure parameter, same problem!
    }
}
```

- **Con**: Same nested-closure capture problem -- `temp` would also taint the
  sending region.
- **Verdict**: Does not solve the problem.

---

## [RES-SEND-007] Recommendation

### Immediate: Verify and Remove Workarounds (Swift 6.3)

The Swift 6.3 reproduction (see [RES-SEND-009]) suggests both workarounds may
be removable. **Verify by testing in the actual codebase before removing.**

**Site 1** — Replace the `nonisolated(unsafe)` workaround with the direct
coroutine expression:

```swift
mutable.value.withLock { deque in
    deque.back.push(element)  // Preferred: uses the Property.View accessor directly
}
```

If this does not compile, fall back to the direct method (Option A):

```swift
mutable.value.withLock { deque in
    deque.push(element, to: .back)  // Fallback: bypasses coroutine entirely
}
```

Either approach eliminates the `nonisolated(unsafe)`, the extra copy, and the
`unsafe` keyword. The `~Copyable` overload at line 85-90 of the same file
already uses `push(_:to:)` successfully.

**Site 2** — Remove the `rawCopy` Array and capture `rawEvents` directly into
the `withLock` closure. This eliminates the per-poll-cycle heap allocation on the
kqueue hot path.

If direct capture still fails to compile, the current workaround remains
correct — the Array allocation is bounded by event count and measurable but not
catastrophic.

### Fallback: Track Compiler Evolution

If Swift 6.3 has NOT fixed the issue in the actual codebase (i.e., the
reproduction is insufficiently faithful), track the Swift compiler's progress on:
- Region checker improvements for coroutine accessors and `~Escapable` integration
- `inout sending` forwarding fixes (swiftlang/swift#82553)
- Potential `sending` annotation on coroutine yields

The ideal fix is for the region checker to understand that:
1. A coroutine accessor's yielded value is in the same region as `self`.
2. `~Escapable` types cannot escape the coroutine scope, so they cannot create
   cross-region dependencies.
3. Operations on the yielded value that only pass Sendable values do not taint
   the `sending` region.

---

## [RES-SEND-008] Minimal Reproduction

The pattern that triggers the failure (prior to Swift 6.3, see [RES-SEND-009]):

```swift
import Synchronization

// ~Copyable, ~Escapable view wrapping a pointer — NOT Sendable
struct ViewTyped<Base, Element>: ~Copyable, ~Escapable {
    let ptr: UnsafeMutablePointer<Base>

    @_lifetime(borrow ptr)
    init(_ ptr: UnsafeMutablePointer<Base>) {
        self.ptr = ptr
    }
}

struct Container<Element> {
    var storage: [Element] = []

    // Coroutine accessor yielding a ~Escapable view (matches Deque.back)
    var view: ViewTyped<Self, Element> {
        mutating _read {
            yield unsafe ViewTyped(&self)
        }
    }

    mutating func directPush(_ element: Element) {
        storage.append(element)
    }
}

extension ViewTyped where Base == Container<Element> {
    // Non-mutating — operates through the pointer
    func push(_ element: Element) {
        unsafe ptr.pointee.storage.append(element)
    }
}

func testPush<Element: Sendable>(
    _ mutex: borrowing Mutex<Container<Element>>,
    _ element: Element
) {
    mutex.withLock { container in
        container.view.push(element)  // The failing expression
    }
}
```

The pattern reduces to: a `_read` coroutine accessor that yields a non-Sendable,
`~Escapable` view wrapping a pointer to the `inout sending` parameter, where an
external value is then passed IN through a method on the yielded view. The region
checker cannot see through the coroutine to verify that the external value does
not taint the `sending` region.

---

## [RES-SEND-009] Swift 6.3 Reproduction Results

### Finding: Reproduction Does Not Fail on Swift 6.3

A minimal reproduction matching the Property.View coroutine pattern (see
[RES-SEND-008]) was built on:

```
Apple Swift version 6.3 (swiftlang-6.3.0.123.5 clang-2100.0.123.102)
Target: arm64-apple-macosx26.0
```

With the full swift-io feature flag set (`NonisolatedNonsendingByDefault`,
`LifetimeDependence`, `Lifetimes`, `SuppressedAssociatedTypes`,
`InferIsolatedConformances`), **all test cases compiled successfully**:

| Case | Expression | Expected | Actual |
|------|-----------|----------|--------|
| Direct mutation | `container.directPush(element)` | Compiles | Compiles |
| Coroutine + value OUT | `container.view.take` | Compiles | Compiles |
| Coroutine + value IN | `container.view.push(element)` | **Fails** | **Compiles** |
| Concrete type push | `container.view.push(42)` | Unclear | Compiles |
| Buffer pointer capture | `rawBuf` captured into `withLock` | **Fails** | **Compiles** |

### Implication

The region checker in Swift 6.3 appears to handle both failure modes:

1. **Coroutine accessor + `sending`**: The checker now reasons through `_read`
   coroutine yields to verify that operations on the yielded value do not taint
   the `sending` region. The `~Escapable` annotation on `Property.View.Typed`
   may now contribute to this analysis — since the view cannot escape, the
   checker can prove the region dependency is scoped.

2. **Closure parameter capture**: The checker now handles non-Sendable captures
   from outer closure parameters alongside `inout sending` parameters in
   synchronous, non-escaping contexts.

### Caveat: Reproduction vs Actual Code

The reproduction uses a simplified `ViewTyped` type that models the essential
traits of `Property.View.Typed` (`~Copyable`, `~Escapable`, pointer-based,
`@_lifetime(borrow ptr)`). The actual code involves additional layers:
`Ownership.Mutable.Unchecked`, the full Deque generic structure, and the
Property.View type hierarchy from swift-property-primitives.

**The workarounds should not be removed without verifying that the actual
expressions compile in the real swift-io codebase.** The reproduction confirms
the compiler CAN handle the pattern; it does not guarantee every variant of the
pattern is covered.

### Recommended Verification

To confirm the workarounds are removable, test these exact changes (one at a time):

**Site 1** — `IO.Event.Registration.Queue.swift:48-54`:
```swift
// Remove nonisolated(unsafe) workaround, use direct expression:
mutable.value.withLock { deque in
    deque.back.push(element)
}
```

**Site 2** — `IO.Event.Queue.Operations.swift:407-415`:
```swift
// Remove rawCopy Array, capture rawEvents directly:
let collected: [Kernel.Event] = IO.Event.Registry.shared.withLock { outer in
    // Use rawEvents directly instead of rawCopy
}
```

If either fails to compile, the reproduction is insufficiently faithful and the
workarounds remain necessary. If both compile, the workarounds can be removed
along with their tracking comments.

---

## [RES-SEND-010] `~Escapable` as Region Safety Evidence

### Observation

`Property.View.Typed` is declared `~Copyable, ~Escapable` with
`@_lifetime(borrow ptr)` on its initializer. This means:

1. The view **cannot escape** the scope in which it is created.
2. The view's lifetime is **bound to the pointer** it wraps.
3. The view cannot be stored, returned, or captured by an escaping closure.

These are exactly the properties needed to prove region safety: if a value
derived from the `inout sending` parameter cannot escape the coroutine's yield
scope, it cannot create a cross-region dependency.

### Current State

The region isolation checker (SE-0414) and the escapability checker (`~Escapable`,
Lifetimes) are separate compiler subsystems. Historically, the region checker did
not consult escapability information when determining whether a coroutine-yielded
value could taint a `sending` region.

The Swift 6.3 reproduction results (see [RES-SEND-009]) suggest that either:
- The region checker now integrates with `~Escapable`/lifetime analysis, or
- The region checker has been improved independently to handle coroutine yields.

Either way, this is the correct direction: `~Escapable` types with lifetime
annotations provide the compiler with exactly the information needed to verify
that coroutine-yielded views maintain `sending` region invariants.

### Implication for Property.View Design

The Property.View pattern was designed with `~Escapable` specifically to enable
safe pointer-based access without ownership transfer. The `sending` composition
issue was a gap between the type system's safety guarantees and the region
checker's ability to verify them. If Swift 6.3 has closed this gap, then
Property.View's design is validated — the `~Escapable` constraint serves as both
a safety mechanism AND a region-checker proof obligation.

---

## References

- [SE-0430: `sending` parameter and result values](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0430-transferring-parameters-and-results.md)
- [SE-0414: Region based Isolation](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0414-region-based-isolation.md)
- [SE-0433: Synchronous Mutual Exclusion Lock](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0433-mutex.md)
- [SE-0474: Yielding accessors](https://github.com/swiftlang/swift-evolution/blob/main/proposals/0474-yielding-accessors.md)
- [Forums: Sending, inout sending, Mutex](https://forums.swift.org/t/sending-inout-sending-mutex/76373)
- [Forums: 'inout sending' parameter cannot be task-isolated](https://forums.swift.org/t/inout-sending-parameter-cannot-be-task-isolated-at-end-of-function/80144)
- [swiftlang/swift#82553: Can't forward `inout sending` argument](https://github.com/swiftlang/swift/issues/82553)
- [swiftlang/swift#77199: Can not assign non-sendable into inout sending](https://github.com/swiftlang/swift/issues/77199)
