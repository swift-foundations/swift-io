# Polling Tick Isolation via checkIsolated / isIsolatingCurrentContext

<!--
---
version: 1.1.0
last_updated: 2026-04-15
status: IMPLEMENTED
tier: 2
related:
  - swift-io/Research/actor-state-visibility-structural-fix.md
  - swift-io/Research/executor-conformance-triage.md
  - swift-io/Research/completion-loop-executor-unification.md
  - swift-io/HANDOFF.md (polling tick isolation handoff)
  - swift-executors/Research/composable-executor-abstractions.md
  - swift-foundations/Experiments/polling-two-phase-api (CONFIRMED)
  - swift-foundations/Experiments/sending-init-weakself-di (REFUTED)
changelog:
  - v1.0: Initial analysis. Three avenues investigated; Avenue A
    (checkIsolated) recommended. Runtime fallback chain verified in
    swiftlang/swift Actor.cpp.
  - v1.1: Status → IMPLEMENTED. Avenue A landed in swift-executors
    (26520c4) + swift-io (9aa07c28). Design record below describes
    the actual implementation and the Handle weak-box that the
    single-assignment `polling: let` required to satisfy the DI rule.
---
-->

## Implementation Status — IMPLEMENTED (2026-04-15)

Avenue A (Custom `checkIsolated` + `isIsolatingCurrentContext` on
`Kernel.Thread.Executor.Polling`) **landed**.

**Shipped commits**:

- `swift-executors 26520c4`: SE-0424 hooks on `Polling` + `Kernel.Thread.Executor`
- `swift-executors 5e00051`: tick parameter `sending @escaping` (was `@Sendable`); `@safe` on class
- `swift-io 9aa07c28`: `assumeIsolated` in tick body; `nonisolated(unsafe)` removed from `state` and `registrations`; `nonisolated` removed from `dispatchEvents`, `handleWaitFailure`, `fatalCleanup`

**Design delta from v1.0 recommendation**:

The recommendation described relaxing `nonisolated(unsafe) var polling: Polling!` back to single-assignment. The actual implementation went further: `polling` is now `nonisolated let`. To satisfy Swift's definite-init rule for `[weak self]` in the tick closure (the closure is created while `self.polling` — the only stored property — is being assigned), a new class-typed weak cell `IO.Events.Actor.Handle` was introduced. The tick captures the Handle (a local class); `handle.actor = self` is written at the tail of `init`, after `self.polling` has been assigned. See `Sources/IO Events/IO.Events.Actor.Handle.swift`.

**Two language options explored and rejected as sufficient replacements**:

- `sending @escaping` at init in place of `@Sendable` — DOES change the closure's sendability model (and was landed as a refactor), but does NOT relax the DI rule. Experiment: `Experiments/sending-init-weakself-di/` (REFUTED).
- Two-phase Polling API (`init(source:)` + `public func start(tick:)`) — would eliminate the Handle entirely. Experiment: `Experiments/polling-two-phase-api/` (all 6 variants CONFIRMED on Swift 6.3 debug + release). Not taken: adds one public method to swift-executors; pure polish, no correctness benefit.

**Non-negotiable**: zero-hop synchronous dispatch from the Polling thread into actor-isolated state. Pull-model alternatives (event channel, async hop per event) are off-table — the entire weak-box + `assumeIsolated` stack exists to preserve zero-hop.

The pre-implementation analysis that follows (contexts, avenues, runtime fallback chain) is retained for historical reference.

---
-->

## Context

`IO.Events.Actor` is an actor pinned to a `Kernel.Thread.Executor.Polling`
via `unownedExecutor`. The Polling executor's tick closure runs on the
actor's OS thread — the same thread that dispatches actor jobs — but
outside a Swift Task context. This means `assumeIsolated` traps with
"Unexpected isolation context" because the runtime cannot verify executor
identity without a current Task.

To work around this, two properties are `nonisolated(unsafe)`:

| Property | Line | Why unsafe |
|----------|------|------------|
| `state` | `IO.Events.Actor.swift:67` | Tick reads `.running` guard |
| `registrations` | `IO.Events.Actor.swift:77` | Tick reads/writes via `dispatchEvents`, `fatalCleanup` |

Three methods are `nonisolated`:

| Method | Line | Role |
|--------|------|------|
| `dispatchEvents` | `:126` | Broadcasts kernel events to channel senders |
| `handleWaitFailure` | `:166` | Classifies wait errors as retry/yield/halt |
| `fatalCleanup` | `:182` | Closes all senders, clears registrations |

Thread safety is guaranteed by construction — the actor is pinned to
the Polling thread, so actor methods and the tick closure are mutually
exclusive on the same OS thread. But the compiler does not know this.

The `nonisolated(unsafe)` annotation works but silently opts out of the
compiler's isolation enforcement. A future refactor could break the
single-thread invariant, and the compiler would not catch it.

### Relationship to Prior Research

| Document | Finding | Status |
|----------|---------|--------|
| [actor-state-visibility-structural-fix.md](actor-state-visibility-structural-fix.md) | AdmissionSlip pattern removes `state` from actor; does NOT address `registrations` access in tick | Verified 2026-04-15: `state` and `registrations` are still `nonisolated(unsafe)` |
| [executor-conformance-triage.md](executor-conformance-triage.md) | IO loops stay as standalone executors (Option D); poll-blocking != condvar-blocking | Verified 2026-04-15: Polling is a separate class, Loop collapsed into Actor |
| [completion-loop-executor-unification.md](completion-loop-executor-unification.md) | Completion.Loop uses primitives-only refactor (Option B); same tick isolation issue exists | Verified 2026-04-15: IO.Completion.Loop has same `nonisolated(unsafe)` pattern |

## Question

How can the tick closure access actor-isolated state (`state`,
`registrations`) without `nonisolated(unsafe)`, given that `assumeIsolated`
traps because there is no Swift Task context on the Polling thread during
tick execution?

## Analysis

### The Runtime Fallback Chain

The Swift concurrency runtime (`Actor.cpp:497-557`) handles `assumeIsolated`
as follows when there is **no current Task context**:

```
1. _taskIsCurrentExecutor(expectedExecutor)
2.   → no current executor tracking info
3.   → call isIsolatingCurrentContext() on expected executor  [since 6.2]
4.     → if true:  return true (isolation verified)
5.     → if false: fall through
6.     → if nil:   fall through (default: returns nil)
7.   → call checkIsolated() on expected executor              [since 6.0]
8.     → if returns normally: return true (isolation verified)
9.     → if crashes: assertion failure (default: fatalError)
```

Both `isIsolatingCurrentContext()` and `checkIsolated()` have default
implementations that do not verify isolation — `nil` and `fatalError`
respectively. Custom executors that own their own thread can override
these to provide thread-identity verification.

**Prior art**: Apple's `DispatchMainExecutor` in `swift-platform-executors`
implements `checkIsolated()` via `_dispatchAssertMainQueue()` — the exact
same pattern: the executor knows which thread it owns and verifies the
caller is on that thread.

### Avenue A: Implement isIsolatingCurrentContext on Polling

Add `isIsolatingCurrentContext() -> Bool?` to `Kernel.Thread.Executor.Polling`
(and `Kernel.Thread.Executor`). The implementation verifies the current
thread matches the executor's thread.

**Mechanism**: `Kernel.Thread.Handle.isCurrent` already exists
(`ISO_9945.Kernel.Thread.Handle.swift:76`), implemented as
`pthread_equal(pthread_self(), rawValue) != 0`. Polling's `threadHandle`
stores the executor's thread identity.

**Sketch** (exact API depends on `~Copyable` optional chaining support):

```swift
extension Kernel.Thread.Executor.Polling {
    public func isIsolatingCurrentContext() -> Bool? {
        // threadHandle is Kernel.Thread.Handle? (~Copyable)
        // isCurrent borrows the handle, compares pthread_self()
        threadHandle?.isCurrent
    }
}
```

If `~Copyable` optional chaining does not compile, alternative
implementations:

| Alternative | Mechanism | Cost |
|-------------|-----------|------|
| Store `pthread_t` as separate `UInt` field | Copy raw thread ID at spawn | +8 bytes per executor |
| Implement `checkIsolated()` instead | `precondition(threadHandle?.isCurrent == true)` | Same, crashes instead of returning Bool |
| Both methods | `isIsolatingCurrentContext` preferred; `checkIsolated` for older runtimes | Maximal compatibility |

**Impact on IO.Events.Actor**: Once `isIsolatingCurrentContext()` returns
`true` on the Polling thread, the tick closure uses:

```swift
{ [weak self] wait in
    guard let self else { return .halt }
    return self.assumeIsolated { isolatedSelf in
        guard isolatedSelf.state == .running else { return .halt }
        do throws(Kernel.Event.Driver.Error) {
            let events = try wait()
            isolatedSelf.dispatchEvents(events)
            return .continue
        } catch {
            return isolatedSelf.handleWaitFailure(error)
        }
    }
}
```

`dispatchEvents`, `handleWaitFailure`, and `fatalCleanup` become regular
`private` methods (not `nonisolated`). `state` and `registrations` lose
`nonisolated(unsafe)`. The compiler enforces isolation.

**The `polling` property**: `nonisolated(unsafe)` on `polling` exists for
a different reason — two-phase init (set to nil, then assigned with
`[weak self]` tick closure). This is not addressed by Avenue A. It is an
orthogonal concern — the `polling` reference is set once in `init` and
never mutated thereafter, so `nonisolated(unsafe)` is correct for that
property.

### Avenue B: Actor-enqueue pattern (from PDF prior art)

Point-Free Video #362 demonstrates the `Actor.run` pattern:

```swift
extension Actor {
    func run<R, Failure: Error>(
        _ body: @Sendable (isolated Self) throws(Failure) -> R
    ) throws(Failure) -> R {
        try body(self)
    }
}
```

This allows synchronous access to actor state after a single `await` hop.
However, calling an actor method from the tick requires either:

- `await self.run { ... }` — but tick is synchronous, not async
- Using a continuation to bridge — but the events buffer is
  `UnsafeBufferPointer` scoped to the tick call; deferring via
  continuation would outlive the buffer

The buffer lifetime constraint is load-bearing. The events buffer is
stack-allocated in `Polling.runLoop()` and the `UnsafeBufferPointer`
is created inside `withUnsafeBufferPointer`. Any mechanism that defers
the dispatch (enqueue a job, await a continuation) cannot safely reference
the buffer without copying it.

Copying the buffer on every poll cycle adds allocation on the hot path.
For a reactor that may poll thousands of times per second with up to 256
events per cycle, this is unacceptable overhead.

**Verdict**: Avenue B does not apply to the tick closure pattern.
`Actor.run` is valuable for call-site isolation squashing (reducing
multiple `await`s to one), but cannot help with synchronous callbacks
from custom executor run loops.

### Avenue C: Language-level mechanism

Three potential language features were considered:

| Feature | Status | Applicability |
|---------|--------|---------------|
| `withTaskExecutorPreference` | Stable (6.0+) | Async only — cannot use from sync tick |
| `assumeOnExecutor` (hypothetical) | Does not exist | Would be equivalent to `assumeIsolated` + `checkIsolated` |
| Custom executor `checkIsolated` / `isIsolatingCurrentContext` | Stable (6.0+ / 6.2+) | **This IS the language-level mechanism** — Avenue A |

Avenue C collapses into Avenue A. The Swift concurrency runtime already
provides the extension point (`isIsolatingCurrentContext` /
`checkIsolated`) — it just needs to be implemented by our executors.

### Comparison

| Criterion | A: checkIsolated | B: Actor.run | C: Language feature |
|-----------|-----------------|--------------|---------------------|
| Eliminates nonisolated(unsafe) on `state` | **Yes** | No (tick is sync) | = A |
| Eliminates nonisolated(unsafe) on `registrations` | **Yes** | No | = A |
| Buffer lifetime safe | **Yes** (sync, same scope) | No (deferred) | = A |
| Hot-path overhead | **Zero** (pthread_equal is ~2ns) | Copy buffer per poll | = A |
| Compiler-enforced isolation | **Yes** (assumeIsolated) | Yes | = A |
| Applies to IO.Completion.Loop | **Yes** (same pattern) | No | = A |
| Requires swift-executors change | **Yes** (~5 LOC per executor) | No | = A |
| Requires swift-io change | **Yes** (~20 LOC) | N/A | = A |
| Runtime version requirement | 6.0+ (checkIsolated) / 6.2+ (isIsolatingCurrentContext) | N/A | = A |

## Detailed Implementation Path

### Step 1: swift-executors — add isIsolatingCurrentContext to Polling

File: `Sources/Executors/Kernel.Thread.Executor.Polling.swift`

Add `isIsolatingCurrentContext() -> Bool?` that returns
`threadHandle?.isCurrent`. If `~Copyable` optional chaining fails to
compile, store a separate `Copyable` thread identity value at thread
creation time.

Also add `checkIsolated()` as a backstop for runtimes that call it
instead of `isIsolatingCurrentContext`:

```swift
public func checkIsolated() {
    guard isIsolatingCurrentContext() == true else {
        preconditionFailure(
            "Polling executor: not on executor thread"
        )
    }
}
```

### Step 2: swift-executors — add isIsolatingCurrentContext to Kernel.Thread.Executor

File: `Sources/Executors/Kernel.Thread.Executor.swift`

Same pattern. The condvar-based executor also owns a thread and has
`threadHandle`.

### Step 3: swift-io — rewrite tick closure to use assumeIsolated

File: `Sources/IO Events/IO.Events.Actor.swift`

Change the tick closure from:

```swift
guard self.state == .running else { return .halt }
// ...
self.dispatchEvents(events)
// ...
return self.handleWaitFailure(error)
```

To:

```swift
return self.assumeIsolated { isolatedSelf in
    guard isolatedSelf.state == .running else { return .halt }
    // ...
    isolatedSelf.dispatchEvents(events)
    // ...
    return isolatedSelf.handleWaitFailure(error)
}
```

### Step 4: swift-io — remove nonisolated annotations

- Remove `nonisolated(unsafe)` from `state` (line 67)
- Remove `nonisolated(unsafe)` from `registrations` (line 77)
- Remove `nonisolated` from `dispatchEvents` (line 126)
- Remove `nonisolated` from `handleWaitFailure` (line 166)
- Remove `nonisolated` from `fatalCleanup` (line 182)

### Step 5: Verify

- `swift test` in swift-executors — existing tests pass
- `swift test` in swift-io — 53/23 green on macOS

### Future: IO.Completion.Loop

The same pattern applies to `IO.Completion.Loop` / `IO.Completions.Actor`
(same tick-on-executor-thread architecture). Once Avenue A lands in
swift-executors, the completion side can adopt it independently.

## Risk Assessment

| Risk | Mitigation |
|------|------------|
| `~Copyable` optional chaining doesn't compile | Store `pthread_t` as separate `UInt` field — Copyable, no chaining issues |
| `assumeIsolated` closure is `@Sendable`, events buffer can't cross | The buffer is captured by the tick closure that's already on the thread; `assumeIsolated`'s closure is non-escaping, so the buffer pointer remains valid |
| `threadHandle` is nil during shutdown | `_shutdown.isSet` breaks the run loop before tick; `checkIsolated` is not called after shutdown |
| `isIsolatingCurrentContext` not available on older deployment targets | `checkIsolated` (6.0+) serves as fallback; we target 6.3+ per [PATTERN-005] |
| `weak self` + `assumeIsolated` interaction | `guard let self` precedes `assumeIsolated`; if self is nil, return `.halt` before the isolation check |

## Outcome

**Status**: RECOMMENDATION

Implement `isIsolatingCurrentContext() -> Bool?` (preferred, 6.2+) and
`checkIsolated()` (backstop, 6.0+) on `Kernel.Thread.Executor.Polling`
and `Kernel.Thread.Executor`. This is the mechanism the Swift concurrency
runtime provides for exactly this situation — synchronous code running on
an executor's thread outside a Task context.

Once implemented, `IO.Events.Actor`'s tick closure uses
`self.assumeIsolated { ... }` and all `nonisolated(unsafe)` annotations
on `state` and `registrations` are removed. The compiler enforces actor
isolation. The fix is zero-overhead on the hot path (`pthread_equal` is
~2ns), requires ~25 LOC across two packages, and applies to both the
reactor (`IO.Events.Actor`) and proactor (`IO.Completions.Actor`) paths.

Avenue B (Actor.run) does not apply — the tick is synchronous and the
events buffer is scope-limited. Avenue C collapses into Avenue A — the
`checkIsolated` / `isIsolatingCurrentContext` protocol requirements ARE
the language-level mechanism.

## References

- `swiftlang/swift/stdlib/public/Concurrency/Actor.cpp:497-557` — runtime fallback chain
- `swiftlang/swift/stdlib/public/Concurrency/Executor.swift:370-444` — `checkIsolated` and `isIsolatingCurrentContext` protocol requirements
- `swiftlang/swift/stdlib/public/Concurrency/ExecutorBridge.swift:34` — `_swift_task_checkIsolatedSwift` bridge
- `swiftlang/swift-platform-executors/.../DispatchMainExecutor.swift:41` — Apple's `checkIsolated` implementation
- `swift-iso/swift-iso-9945/.../ISO_9945.Kernel.Thread.Handle.swift:76` — `isCurrent` via `pthread_equal`
- `swift-foundations/swift-executors/.../Kernel.Thread.Executor.Polling.swift:89-253` — current Polling implementation (no `checkIsolated`)
- `swift-foundations/swift-io/.../IO.Events.Actor.swift:49-113` — current actor with `nonisolated(unsafe)`
- Point-Free Video #362 "Isolation: Actor Enqueuing" (Apr 13, 2026) — `Actor.run` pattern (Avenue B prior art)
- [actor-state-visibility-structural-fix.md](actor-state-visibility-structural-fix.md) — AdmissionSlip proposal (orthogonal to tick isolation)
