# IO.Context as Actor — Analysis

<!--
---
version: 3.0.0
last_updated: 2026-04-14
status: SUPERSEDED_BY io-blocking-executor-binding.md v4.0
tier: 2
related:
  - swift-io/Research/io-blocking-executor-binding.md (v4.0 — supersedes)
  - swift-io/Research/io-witness-design-literature-study.md (v4.0)
  - swift-io/Research/io-witness-borrowing-async-tension.md
  - swift-io/HANDOFF-actor-runner-investigation.md
  - Point-Free #362 "Isolation: Actor Enqueuing"
  - /Users/coen/Developer/swift-primitives/swift-standard-library-extensions/Sources/Standard Library Extensions/Actor.swift
changelog:
  - v3.0: Updated for **Shape B** (io-blocking-executor-binding v4.0). v2.0 said
    "IO is the actor, Context stays @Witness internal". Shape B refines:
    (a) `IO` itself becomes the `@Witness` struct (Context as a separate type is
    retired — its responsibility folds into IO). (b) Each strategy's impl is an
    internal actor holding a concrete executor (not existential). This resolves
    all six of v1.0's concerns including the ref-type semantics one (Shape A
    kept ref-type; Shape B restores value-type capability).
  - v2.0: Partially superseded. v1.0 asked "Context as actor?" and answered
    "No — stays @Witness". That conclusion is correct and preserved. But the
    investigation that followed (io-blocking-executor-binding.md v3.0) shifted
    the ACTOR up one level: `IO` itself becomes the public actor, while
    `Context` stays @Witness internally. This document updated to reflect the
    reconciliation.
  - v1.0: Initial analysis. Rejected making Context an actor on six grounds
    (testing infra, wrong-problem fit, per-call overhead, @Sendable, reference
    semantics, strategy swappability).
---
-->

## Question

Should `IO.Context` be an actor instead of a @Witness struct?

## The Actor.run Pattern (Point-Free #362)

The `Actor.run` pattern provides:
1. **Single suspension**: `try await bank.run { bank in ... }` — one hop to enter
   the isolation domain, then all calls inside are synchronous.
2. **`isolated` parameter**: Proves to Swift the body runs in the actor's domain.
   Sync access to actor state, no interleaving.
3. **Custom SerialExecutor**: The actor can specify which thread/queue jobs run on
   via `unownedExecutor`.
4. **Atomicity**: No other work on the actor interleaves during `run`.

Applied to IO:
```swift
actor IOContext {
    nonisolated var unownedExecutor: UnownedSerialExecutor {
        blockingExecutor.asUnownedSerialExecutor()
    }

    func read(from: borrowing Kernel.Descriptor, into: Memory.Buffer.Mutable) throws(IO.Error) -> Int {
        // sync on the actor's executor — blocking thread
    }
}

// Consumer:
try await context.run { ctx in
    let n = try ctx.read(from: fd, into: buf)   // sync
    await someOtherWork()                         // might hop
    try ctx.write(to: fd, from: buf)             // re-enters actor → back on blocking thread
}
```

## Arguments FOR

| Benefit | Details |
|---------|---------|
| **Mandatory executor affinity** | Actor isolation is enforced by the language, not advisory like `executorPreference`. Every call to `ctx.read()` is guaranteed on the actor's executor. |
| **Auto re-hop** | After `await someOtherWork()` hops executors, the next `ctx.read()` forces a re-entry to the actor → back on the blocking thread. The executor hop problem is solved. |
| **Sync within isolation** | Inside `actor.run`, calls are sync. `borrowing Kernel.Descriptor` works — no async boundary within the isolated scope. |
| **Atomicity** | Multiple I/O calls within `run` are atomic — no interleaving from other tasks on the same actor. |

## Arguments AGAINST

### 1. @Witness incompatibility

The @Witness macro generates structs, not actors. Making Context an actor means
losing: `unimplemented()`, `Calls` enum, `observe()`, prisms — the entire testing
and observation infrastructure that motivated @Witness in the first place.

### 2. Actor solves the wrong problem

Point-Free's `Actor.run` addresses **atomicity of shared mutable state** — Bank
has accounts that can be concurrently modified. The actor serializes access to
prevent race conditions between concurrent transactions.

IO.Context has **no shared mutable state**. It's a struct of closures. The closures
capture resources (thread pool, kernel event sources), but those resources are
managed by the factory, not by the Context. Each I/O operation is independent —
there's no atomicity requirement between a `read` and a `write`.

### 3. Per-call overhead

Actors enqueue jobs to their executor for every cross-isolation call. Even with
`Actor.run` collapsing multiple calls into one job, the enqueue machinery
(allocation, priority handling, executor dispatch) runs per-run.

The @Witness approach has zero per-call overhead — it's a direct closure call.
For hot-path I/O (thousands of reads/writes per second), actor overhead is
measurable.

### 4. @Sendable requirement on body

The `Actor.run` body must be `@Sendable` — it crosses an isolation boundary.
This forces all captured values to be Sendable. `Kernel.Descriptor` IS Sendable,
but the requirement propagates: any buffer, state, or helper captured by the body
must also be Sendable. This is a viral constraint the current design avoids.

### 5. Reference type semantics

Actors are reference types (heap-allocated, reference-counted). The current
IO / IO.Context are value types (stack-allocated, no reference counting).
Value semantics are simpler for the consumer and more efficient for short-lived
scopes.

### 6. Strategy swappability

With @Witness, the strategy is a value — `IO.blocking()`, `IO.bestAvailable()`,
`IO.fake()`. Different closures, same struct type. With actors, the strategy
becomes a different actor TYPE (BlockingContext vs ReactorContext). This either
requires a protocol (existential overhead) or generics (monomorphization bloat).

## The Executor Hop Concern

The primary motivation for Context-as-actor is the executor hop: after `await`
inside the body, the next sync I/O call might run on the cooperative pool.

Current state: `Task(executorPreference: executor)` is advisory but **proven
working** with `Kernel.Thread.Executor` (16 concurrent calls with Task.yield
between I/O ops, all complete within time limit).

If mandatory affinity is needed in the future, **TaskExecutor (SE-0417)** provides
task-level executor binding without actor overhead. The task's default executor
is set once — all resumptions prefer it.

## Recommendation

**NO — Context should remain a `@Witness` struct. Still correct.**

| Concern | Resolution |
|---------|-----------|
| Executor hop | See reconciliation note below — resolved at the `IO` level, not `Context` |
| Zero-overhead dispatch | @Witness gives direct closure calls inside the actor's executor |
| Testing infrastructure | @Witness provides unimplemented/observe/Calls; kept intact |
| Strategy swappability | Struct of closures is a value; each strategy builds its own Context |
| Shared mutable state | Context has none; serialization comes from the `IO` actor, not Context |
| @Sendable propagation | Not relevant — Context is internal, never crosses isolation boundaries |

## Reconciliation with io-blocking-executor-binding.md v4.0 (Shape B)

This document was written when the candidate refactor was "Context as actor." That
framing is still the wrong answer. The final v4.0 recommendation takes a different
path: **`IO` itself becomes the `@Witness` struct** (absorbing Context's role),
and **each strategy's runtime is an internal actor** with a concrete executor type.

```swift
// Public — IO IS the witness (Context as a separate type is retired).
@Witness
public struct IO: Sendable {
    let _read:  @Sendable (_ from: borrowing Kernel.Descriptor, _ into: Memory.Buffer.Mutable) async throws(IO.Error) -> Int
    let _write: @Sendable (...) async throws(IO.Error) -> Int
    let _accept: @Sendable (...) async throws(IO.Error) -> Kernel.Descriptor
    let _close: @Sendable (...) async -> Void
    let _unownedExecutor: @Sendable () -> UnownedSerialExecutor
}

// Internal — per-strategy actor with concrete executor.
internal actor Actor {
    let executor: Kernel.Thread.Executor   // concrete, not existential
    func read(from fd: borrowing Kernel.Descriptor, ...) throws(IO.Error) -> Int { ... }
    // etc.
}
```

This resolves **all six** v1.0 concerns:

1. **Testing infra** — `@Witness` applied directly to public `IO` generates
   `IO.unimplemented()`, `IO.fake(...)`, `IO.observe(...)` as public helpers at
   no extra cost. Cleaner than v2.0's "internal Context wrapper factories" story.
2. **Wrong-problem fit** — the impl actor provides executor affinity (the right
   problem for it). The IO witness stays a capability record (the right problem
   for it). Clean separation — the theoretical layering becomes architectural.
3. **Per-call overhead** — yes, `await io.read(...)` has a hop through the
   witness closure into the impl actor. The shared-executor pattern from TCA26
   recovers zero-hop calls when the application actor shares the impl's executor
   (app actor's `unownedExecutor` forwards `io.unownedExecutor`). Measured
   ~11 ns/op shared vs ~3.9 µs unshared.
4. **@Sendable requirement** — the witness closures are `@Sendable` internally
   (they capture the impl actor, which IS Sendable), but consumers never write
   body closures and their captures never cross isolation boundaries through the
   public API. Main win over v2.0's Option B.
5. **Reference type semantics** — Shape B restores value-type semantics for the
   capability. `IO` is a struct; the actor reference lives inside the closures'
   captures. Consumers pass `IO` around by value (it's `Sendable`). This is the
   biggest upgrade from Shape A (v3.0 intermediate proposal) to Shape B.
6. **Strategy swappability** — each factory constructs an impl actor of its own
   type (`Actor`, `EventsImpl`, `CompletionsImpl`) with a different
   concrete executor type. Consumer sees only `IO`; the impl types never leak.
   No existentials, no protocol erasure.

## v1.0 analysis preserved

The v1.0 "Arguments FOR making Context an actor" remain accurate for `Context`:
they correctly argue that Context-as-it-was-originally-framed is a capability,
not shared state, and therefore does not need actor semantics. The "Arguments
AGAINST" remain accurate too: a ref-type actor for the capability record is
worse than a value-type struct.

What v1.0 didn't anticipate: the actor semantics are needed NOT for the
capability, but for the RUNTIME that backs it (mandatory thread binding,
executor affinity). That runtime is a separate type (`Actor` etc.) and
lives behind the capability, not as the capability.

The v1.0 executor-hop concern was under-examined. That concern motivated the
full investigation recorded in HANDOFF-actor-runner-investigation.md, which
landed on Shape B — a two-type design that preserves v1.0's `@Witness` insight
while adding the missing executor-affinity runtime.

## References

- `swift-io/Research/io-blocking-executor-binding.md` (v3.0 — Option F recommendation)
- `swift-io/HANDOFF-actor-runner-investigation.md` — full experiments and Q&A
- `/Users/coen/Developer/pointfreeco/TCA26/Sources/ComposableArchitecture2/StoreActor.swift:198` — production precedent for shared-executor pattern
- Point-Free #362, "Isolation: Actor Enqueuing" (2026-04-13)
- `Actor.swift` — `/Users/coen/Developer/swift-primitives/swift-standard-library-extensions/`
- SE-0417: Task Executor Preference
- SE-0461: Run nonisolated async functions on caller's actor by default
- `swift-io/Research/io-witness-design-literature-study.md`
- Brachthaeuser et al., "Effects as Capabilities" (2020, OOPSLA)
