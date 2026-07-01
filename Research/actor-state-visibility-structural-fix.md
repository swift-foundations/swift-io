# Actor-State Visibility: Structural Fix

<!--
---
version: 1.1.0
last_updated: 2026-04-13
status: PROPOSAL (workaround landed — structural issues remain)
tier: 2
---
-->

## Context

> **Update 2026-04-13**: The immediate miscompilation is worked around by removing
> `Mutex<Shutdown.Token?>` from `IO.Event.Selector.Scope` (commit 6dad19ba). All three
> Shutdown tests now pass in release mode. The structural lifetime findings below remain
> open — the Mutex removal breaks the compiler bug's trigger chain but does not address
> the `Scope.selector` escape hole or the underlying CopyToBorrowOptimization defect.

Three tests in `IO.Event.Selector.Shutdown.Tests.swift` previously failed in release mode
(`swift test -c release -Xswiftc -Xllvm -Xswiftc -sil-disable-pass=CopyPropagation`):

- `shutdown rejects new registrations` (line 36)
- `shutdown gate: operations after shutdown throw` (line 127)
- `typed errors: lifecycle is not a leaf error` (line 178)

All three follow the same pattern:

```swift
let scope = try await IO.Event.Selector.Scope()
let selector = scope.selector
await scope.close()
_ = try await selector.register(
    Kernel.Descriptor(_rawValue: -1),
    interest: .read
)   // expected: throws .shutdownInProgress
    // actual:   throws .failure(.invalidDescriptor)
```

The pivotal observation: `register()` reaches the `dup(-1)` syscall and
fails with `EBADF`, which means the `guard state == .running` line in
`Runtime.register()` (`IO.Event.Runtime.swift:92`) returned **true** —
even though `Runtime.shutdown()` set `state = .shuttingDown` four lines
earlier in the parent's session.

Debug mode passes (379/379). Release mode fails reliably. The handoff
([HANDOFF-actor-state-visibility-fix.md](../HANDOFF-actor-state-visibility-fix.md))
characterises this as a memory-visibility bug exposed by `Loop.enqueue()`'s
inline-fallback path (`IO.Event.Loop.swift:149`).

This document is a structural fix proposal — not a memory-ordering patch.
The goal is to make this class of bug **structurally impossible**, refactor-proof,
enforced by the type system rather than by atomic discipline.

### Relationship to Prior Research

| Document | Finding carried forward | Verified |
|----------|----------------------|----------|
| [executor-first-architecture.md](executor-first-architecture.md) | Phase 3 collapses sync primitives to 0 by pinning Runtime to integrated Loop | Verified 2026-04-07: `IO.Event.Loop` and `IO.Event.Runtime` exist and use the integrated pattern |
| [completion-queue-ownership-redesign.md](completion-queue-ownership-redesign.md) | Lifecycle state belongs at the serialization point that owns the OS thread; "ownership subsumes synchronization" | Carried forward as design principle |
| [perfect-lifecycle-design.md](perfect-lifecycle-design.md) | Shutdown is a lifecycle concern, not an operational failure — must be visible at the boundary, not deep inside the actor | Carried forward |
| `feedback_test_hang_timeouts.md` (memory) | Fix A: `Kernel.Thread.Executor.enqueue()` falls back to inline `runSynchronously` when run loop is dead, to prevent hangs on post-shutdown jobs | Verified 2026-04-07: pattern is inherited verbatim by `IO.Event.Loop.enqueue()` (`IO.Event.Loop.swift:149`) |

## Question

Can we eliminate cross-thread reads of actor-isolated lifecycle state, so
that the failing scenario cannot reach the `dup(-1)` syscall regardless of
how the compiler optimises the actor's `state` load?

Stronger requirement: can the **type system** enforce the fix, so that a
future refactor cannot accidentally re-introduce the bug?

## Confirmed Root Cause

### What is reproduced

| Configuration | Result |
|---------------|--------|
| `swift test` (debug) | All 3 tests pass |
| `swift test -c release -Xswiftc -Xllvm -Xswiftc -sil-disable-pass=CopyPropagation` | All 3 tests fail with "Expected shutdownInProgress, got Failure: Invalid descriptor" |

The release-mode failure is deterministic. The test fails on the very
first iteration. The build cannot omit the `-sil-disable-pass=CopyPropagation`
flag because of an unrelated SIL verification crash in
`Kernel.File.Write.Streaming.write(chunk:to:)` (separate Swift 6.3 bug,
tracked under `project_optimize_none_bug`).

### What is *not* reproduced

A minimal experiment was built at `Experiments/actor-state-cross-thread-inline/`
to isolate the alleged memory-visibility issue:

- Custom `SerialExecutor` backed by a single OS thread (matches `IO.Event.Loop`'s structure)
- `enqueue()` with the same inline-fallback pattern (`runSynchronously` when `isRunning == false`)
- `actor Runtime` pinned via `unownedExecutor` with a `private var state: State` field
- An `Atomic<UInt8>` "mirror" written next to `state` for cross-validation
- Five variants (V1 baseline, V2 mirror compare, V3 1000-iteration loop, V4 swift-io two-call mimic, V5 side-effect after state check)

Built and run in `-c release` with `-Xllvm -sil-disable-pass=CopyPropagation`
to match swift-io's exact compilation flags. **Result: 0 bug observations
in 1003 attempts.** The minimal pattern does not reproduce the failure.

This is a critical finding. It means one of:

1. **The compiler optimisation is sensitive to a specific code shape** present
   in `IO.Event.Runtime` but absent from the experiment — possibly the actor
   method having multiple side-effecting paths after the state check, or
   cross-module inlining via `@_optimize(none)` on `Async.Channel.Unbounded`.
2. **The interaction between `-sil-disable-pass=CopyPropagation` and
   whole-module optimisation produces a SIL miscompile** specific to swift-io's
   actor + driver layout. The CP-disable flag is itself a workaround for a
   separate SIL crash; the combination is a heavily-pessimised, off-the-canonical-path
   release build.
3. **The bug is actually somewhere else entirely** — the parent's debug print
   diagnosis (`DEBUG: register called, state = running`) may be misleading us.
   The store-to-`state` may be eliminated entirely by the optimiser as
   "unobserved", or the load may be folded against the initial value.

I cannot conclusively distinguish (1)/(2)/(3) without spending substantial
time reducing swift-io to a minimum repro for upstream submission. **The
structural fix proposed below does not require this distinction** — it
removes the load entirely from the failure path, so whichever miscompile
or optimisation is responsible becomes irrelevant.

### Why this matters for the design

**The bug should not be treated as a memory-ordering bug.** The minimal
experiment shows that vanilla actor-isolated state access *does* respect
cross-thread happens-before in the inline-fallback case. The failure is
some specific compiler-cross-product effect, not a fundamental issue with
the pattern.

The right response is therefore *not* "use atomics on the actor state"
(option C in the handoff), because that admits a problem we have not
proven exists at the level the parent feared. The right response is
**"do not perform admission via actor-isolated state at all"** —
because doing so creates a load that any future compiler quirk could
mis-handle, AND because admission is fundamentally a lifecycle concern
that does not need actor isolation in the first place.

## The Structural Fix: Admission Slip Pattern

### Principle

> **Lifecycle state belongs at the boundary that owns the lifecycle.
> Operations carry a typed proof of admission obtained at the boundary,
> not after the actor hop.**

This rephrases the parent's handoff hypothesis ("split Runtime into
lifecycle vs operations") and adds the type-system enforcement layer:
the proof of admission is a `~Copyable` value, the compiler enforces
its lifecycle, and any future operation that needs admission control
naturally adopts the same shape because the type makes the contract
self-documenting.

### The new types

```swift
extension IO.Event.Loop {
    /// A typed proof that admission was checked synchronously against the
    /// Loop's lifecycle flag *before* the actor hop. Consumed by the actor
    /// method that performs the operation.
    ///
    /// `~Copyable`: at most one operation per slip, enforced by the compiler.
    /// `Sendable`: crosses the actor isolation boundary into the Runtime.
    ///
    /// Cannot be constructed directly — only `Loop.admit()` can mint one.
    /// Cannot be retained for later use — the actor method consumes it on entry.
    public struct AdmissionSlip: ~Copyable, Sendable {
        /// Phantom storage. The slip is a marker; its lifetime is its proof.
        @usableFromInline
        internal init() {}

        /// Consumed by actor methods to acknowledge admission was checked.
        @inlinable
        consuming func acknowledge() {}
    }
}
```

```swift
extension IO.Event.Loop {
    /// Lifecycle flag — the only place lifecycle state lives.
    ///
    /// Set by `requestShutdown()` (called from the Loop's own thread under
    /// the actor's serialization). Read synchronously by `admit()` from
    /// arbitrary caller threads.
    ///
    /// Uses `Atomic<UInt8>` with explicit `.releasing` / `.acquiring`
    /// ordering — independent of actor isolation, immune to whatever
    /// release-mode optimisation breaks the actor `state` load.
    private let lifecycle: Atomic<UInt8> = Atomic(0)
    // 0 = running, 1 = shuttingDown

    /// Synchronous admission check. Throws `shutdownInProgress` if the
    /// lifecycle flag is set; otherwise mints a slip that the caller must
    /// pass to a Runtime actor method.
    ///
    /// **Always called from the caller thread, before any actor hop.**
    /// No actor isolation involvement, no inline-fallback path.
    package func admit() throws(IO.Event.Failure) -> AdmissionSlip {
        if lifecycle.load(ordering: .acquiring) != 0 {
            throw .shutdownInProgress
        }
        return AdmissionSlip()
    }

    /// Requests lifecycle transition to shutdown. Called from
    /// `Runtime.shutdown()` (which runs on this Loop's executor thread).
    ///
    /// Sets the lifecycle flag with release ordering, then sets the halt
    /// flag for the run loop. After this call, all subsequent `admit()`
    /// calls will throw — including those running inline because the run
    /// loop has already exited.
    package func requestShutdown() {
        lifecycle.store(1, ordering: .releasing)
        shouldHalt = true
    }
}
```

### The new actor method shapes

```swift
extension IO.Event.Runtime {
    /// Register a descriptor with the driver.
    ///
    /// **Requires** an `AdmissionSlip` from `Loop.admit()` — the compiler
    /// enforces that admission was checked before this method runs.
    ///
    /// The actor method no longer reads `state`. There is no `state` field.
    /// Lifecycle is the Loop's responsibility, not the actor's.
    package func register(
        slip: consuming IO.Event.Loop.AdmissionSlip,
        descriptor: borrowing Kernel.Descriptor,
        interest: IO.Event.Interest
    ) throws(IO.Event.Failure) -> IO.Event.ID {
        slip.acknowledge()  // consumes the slip — single use enforced

        // Admission already checked. Proceed directly to the operation.
        let duped: Kernel.Descriptor
        do {
            duped = try Kernel.Descriptor.Duplicate.duplicate(descriptor)
        } catch {
            switch error {
            case .handle: throw .failure(.invalidDescriptor)
            case .tooManyOpen: throw .failure(.platform(.POSIX.EMFILE))
            case .platform(let e): throw .failure(.platform(e.code))
            }
        }

        var descriptorOpt: Kernel.Descriptor? = consume duped
        do throws(IO.Event.Error) {
            return try executor.withDriver { driver throws(IO.Event.Error) in
                try driver.register(descriptor: descriptorOpt.take()!, interest: interest)
            }
        } catch {
            throw .failure(error)
        }
    }

    /// Shut down the event system. Sets the lifecycle flag *first*
    /// (synchronous, with release ordering), then performs the actor-level
    /// teardown.
    package func shutdown() async -> Bool {
        // Set the lifecycle flag BEFORE doing any other work. This is what
        // makes the structural fix work — admission checks running on
        // other threads now see .shuttingDown via the atomic.
        executor.requestShutdown()

        // ... rest of shutdown body unchanged: drain registrations, close
        // senders, deregister in driver, set executor.shouldHalt = true.
    }
}
```

### The new caller-side shape

```swift
extension IO.Event.Selector {
    package func register(
        _ descriptor: borrowing Kernel.Descriptor,
        interest: IO.Event.Interest
    ) async throws(IO.Event.Failure) -> IO.Event.Register.Bundle {
        // Synchronous admission check on the caller thread, BEFORE the
        // actor hop. No memory-visibility dependency on actor dispatch.
        let slip = try executor.admit()

        // Actor hop with the slip. The runtime method consumes it.
        let id = try await runtime.register(
            slip: consume slip,
            descriptor: descriptor,
            interest: interest
        )

        // ... rest of register() body unchanged: create channels, publish.
    }
}
```

### Why the failing test now passes

Trace the failing scenario through the new shape:

1. `let scope = try await IO.Event.Selector.Scope()` — creates Loop, Runtime, lifecycle flag = 0.
2. `await scope.close()` runs `Runtime.shutdown()`, which calls
   `executor.requestShutdown()` synchronously **before** any other work.
   `lifecycle` becomes 1 with `.releasing` ordering on the Loop's own thread.
3. Loop thread exits its run loop, runs `shutdownCleanup`, sets `isRunning = false`.
4. `executor.shutdown()` joins the thread on the caller side.
5. `try await selector.register(Kernel.Descriptor(_rawValue: -1), ...)` is called.
6. **`Selector.register()` calls `try executor.admit()` on the caller thread.**
   This loads `lifecycle` with `.acquiring` ordering. Reads 1. Throws
   `.shutdownInProgress`.
7. The actor hop never happens. The `dup(-1)` syscall never runs. The
   inline-fallback path is irrelevant — there is no register-actor-job to
   enqueue, because the synchronous admission check refused before the
   `await runtime.register(...)` call.

### Why this is refactor-proof

The compiler enforces the contract via the `~Copyable AdmissionSlip` type:

| Refactor scenario | Compiler reaction |
|-------------------|-------------------|
| Add a new actor method `Runtime.something()` that needs admission | Method must take `slip: consuming AdmissionSlip` parameter to compile if the call site uses the established pattern. Code review enforces the parameter on new methods that need admission control. |
| Forget to call `executor.admit()` and pass a slip | `runtime.something(slip: ...)` is missing its required argument — compile error. |
| Try to reuse a slip for two operations | Second use is a use-after-consume — compile error. |
| Try to construct a slip directly | `AdmissionSlip` initializer is `internal` — only `Loop.admit()` can mint one. Cross-module construction is impossible. |
| Try to store a slip in a field for later use | The slip is `~Copyable`. It can be moved into a stored optional, but each storage point reduces ergonomics until it's obvious that the developer is fighting the type. The natural shape is "obtain → consume immediately". |
| Move admission state back into the actor | The actor's `state` field is gone. Re-adding it would re-introduce the bug, but `Loop.admit()` would still be the only legitimate path. Code review catches the regression. |

The strongest guarantee is the **non-existence of the actor `state` field**.
There is nothing to mis-read across threads because the actor no longer
holds lifecycle state. Six months from now, a developer adding a new
admission-controlled operation will look at `register` for the pattern,
see the `slip:` parameter and the `executor.admit()` call, and copy the
shape. There is no place for a stale read to creep back in.

### What about in-flight operations?

The slip pattern handles the simple case (call after shutdown). It also
naturally handles the in-flight race:

- Caller A calls `executor.admit()` → reads `lifecycle == 0`, gets a slip, suspends on the actor hop.
- Caller B calls `Runtime.shutdown()` → sets `lifecycle = 1`, halts the loop.
- Caller A's actor method runs (either before B's shutdown body via
  serialisation, or after via inline fallback). It already has its slip.
  The actor method proceeds without re-checking lifecycle.

This is correct:

- If A's method runs **before** B's shutdown body completes, it operates
  on a still-live driver — succeeds normally.
- If A's method runs **after** B's shutdown body has drained the
  registrations (via inline fallback because the loop is dead), it tries
  to call `executor.withDriver` on a driver that has already had all its
  registrations torn down. This may surface as `.failure(.driverError)`
  or similar — a real I/O error, not a stale-state read.

The race window where a slip is held but the driver is dead is **narrow
by construction**: the slip is obtained immediately before the actor
hop, and the actor method consumes it on entry. The window is roughly
"the time between `executor.admit()` returning and `runtime.register`'s
body starting". This is microseconds. Operations that miss this window
were already a race against shutdown; they get a leaf I/O error instead
of `.shutdownInProgress`. This is acceptable and matches every other
production framework.

For workloads that need stronger guarantees ("shutdown waits for in-flight
ops"), the existing actor serialisation already provides it on the happy
path: `Runtime.shutdown()` runs as an actor method, so it serialises
naturally with any other actor methods that started before it. The slip
pattern does not weaken this — it just removes the need to re-check
lifecycle inside the operation method.

## Comparison Matrix

The handoff lists three options:

- **Option A**: Remove the inline fallback. Re-introduces hangs. **Rejected.**
- **Option B**: Lift lifecycle to Loop with `Atomic<Bool>`, check synchronously
  before actor hop.
- **Option C**: Make actor `state` an `Atomic<UInt8>`. Smallest diff.

Plus this proposal:

- **Option D**: Slip pattern — lift lifecycle to Loop AND make admission a
  typed `~Copyable` proof obtained synchronously.

| Criterion | A: Remove inline | B: Loop atomic | C: Actor atomic | **D: Slip pattern** |
|-----------|------------------|----------------|-----------------|---------------------|
| Eliminates the failing-test bug | Yes (by hanging instead) | Yes | Yes | **Yes** |
| Re-introduces hang risk | Yes — exact problem Fix A solved | No | No | **No** |
| Removes actor state load from failure path | N/A | Yes | No (still in actor, just atomic) | **Yes** |
| Refactor-proof against future bugs | No | Weak — code review only | No — every new field has the same risk | **Yes — compiler-enforced via `~Copyable`** |
| Type-system enforcement | None | None | None | **`~Copyable AdmissionSlip`** |
| Touches actor `state` field | N/A | Removes it | Replaces it with `Atomic<UInt8>` | **Removes it** |
| Hot-path overhead | -∞ (deadlocks) | One atomic load | One atomic load | **One atomic load** |
| Cold-path overhead | N/A | Same as today | Same as today | **+1 ~Copyable move** |
| Migration size | Trivial revert | ~40 lines | ~10 lines | **~80 lines** |
| Existential leakage risk | Low | Low | Low | **Low** |
| Compatible with `[API-ERR-001]` typed throws | Yes | Yes | Yes | **Yes** |
| Compatible with "no `nonisolated(unsafe)`" rule | Yes | Yes | Yes | **Yes** |
| Survives the unidentified compiler optimisation | No | Yes (atomic load is opaque to compiler) | Yes | **Yes** |
| Provides authoritative single source of truth | N/A | Yes | No (actor + Loop both relevant) | **Yes** |
| Friendly to addition of *more* admission-controlled ops | Same as today | Adds a manual check at each new call site | Same as today | **Compiler enforces slip on each new actor method** |

D is strictly stronger than B on the refactor-proofness axis. Both fix
the symptom; D additionally fixes the *class* of bug by making the
unsafe pattern impossible to express.

D's only cost over B is the ~Copyable type definition (~10 lines) and the
slight call-site verbosity (`let slip = try executor.admit(); try await
runtime.register(slip: consume slip, ...)` vs. plain `try await
runtime.register(...)`). For the cold path of register/deregister, this
is negligible.

D's only cost over C is the migration size. C is ~10 lines because it
just changes one field. D rewrites the admission story across the
Selector ↔ Runtime interface.

## Migration Path

### Files to change

1. **New file**: `Sources/IO Events/IO.Event.Loop.AdmissionSlip.swift`
   — defines the `~Copyable, Sendable` slip type. Single struct, ~40
   lines including doc comments. Follows `[API-IMPL-005]` one-type-per-file.

2. **`Sources/IO Events/IO.Event.Loop.swift`**
   - Add `private let lifecycle: Atomic<UInt8>` field initialised to 0.
   - Add `package func admit() throws(IO.Event.Failure) -> AdmissionSlip`.
   - Add `package func requestShutdown()` (sets the atomic, sets `shouldHalt`).
   - Existing `enqueue()` inline-fallback stays — it is no longer the
     source of incorrectness, just the emergency-cleanup path.

3. **`Sources/IO Events/IO.Event.Runtime.swift`**
   - Remove `enum State` and `private var state: State` field.
   - Remove `func enter()` (no longer needed).
   - Change `register()` signature to take `slip: consuming AdmissionSlip` first.
   - Change `deregister()` signature similarly.
   - Update `shutdown()` to call `executor.requestShutdown()` first
     (synchronous, with release ordering).
   - Remove `guard state == .running` checks from `register()`,
     `deregister()`, `arm()`, `publish()`, `deregisterForgotten()`. The
     slip-bearing methods don't need the check; the fire-and-forget
     methods (`arm`, `publish`, `deregisterForgotten`) already accepted
     post-shutdown calls as no-ops. They stay.

4. **`Sources/IO Events/IO.Event.Selector.swift`**
   - In `register()`: add `let slip = try executor.admit()` before the
     actor hop. Pass `slip: consume slip` to `runtime.register(...)`.
   - In `deregister()` (both overloads): same pattern.
   - `rearm()` does not need a slip — `arm()` is fire-and-forget and
     always was a no-op after shutdown.

5. **No test changes** — the failing tests should pass as-is, because
   the new admission path matches the existing test contract
   (`shutdownInProgress` thrown on post-shutdown register).

### Order of operations

| Step | Change | Verifies |
|------|--------|----------|
| 1 | Create `AdmissionSlip` type | Compiles in isolation |
| 2 | Add `lifecycle` field, `admit()`, `requestShutdown()` to Loop | Loop compiles, no callers yet |
| 3 | Update `Runtime.shutdown()` to call `requestShutdown()` first; keep `state` field temporarily for compatibility | Runtime still works under old contract |
| 4 | Add new `register(slip:descriptor:interest:)` overload to Runtime; keep old `register(descriptor:interest:)` | Both overloads compile |
| 5 | Update `Selector.register` to use the new path with the slip | Compiler shows old `register` is now dead |
| 6 | Remove old `Runtime.register(descriptor:interest:)`, `state` field, `enter()` | Run tests in debug — should still pass |
| 7 | Run tests in release with the SIL flag — confirm three failing tests now pass | Done |
| 8 | Repeat steps 4–6 for `deregister` | |

After step 7, the bug is fixed. Steps 8+ extend the pattern to other
admission-controlled operations.

### Test strategy

- **Existing failing tests pass**: `shutdownRejectsNewRegistrations`,
  `shutdownGate`, `typedErrorsLifecycleNotLeaf`. These are the canary.
- **Non-shutdown tests must remain passing**: the 376 tests that pass
  in release mode today (and all 379 in debug).
- **In-flight race test**: `shutdownDrainsPendingRepliesRace` (line 60).
  This existing test starts a register in a `Task` while shutting down
  in the main flow. The slip is obtained when the Task starts; if it's
  before shutdown, the actor method runs and may succeed or hit a leaf
  error; if it's after, `executor.admit()` throws `.shutdownInProgress`.
  Either way, the test invariant ("must be shutdownInProgress if it
  fails") may need a small relaxation if the actor method now returns
  a leaf I/O error in the race window. Verify the test assumptions
  before declaring done.
- **No new tests required for the structural fix itself** — the
  type-system enforcement is the test. If a refactor breaks the slip
  contract, the build fails.

### Risk assessment

| Risk | Mitigation |
|------|------------|
| Slip discipline isn't actually enforced because someone defaults the parameter | Do not provide a default value. The parameter is required. |
| `consume slip` syntax inside the call is verbose | Hidden behind the cold-path register API. The hot path (channel arms) doesn't need slips. |
| The migration introduces a transient state where both old and new actor methods exist | Steps 4–5 create the overload, step 6 removes the old. Window is one PR. |
| Removing `state` breaks some other caller we haven't found | Grep for `state == .running` and `state = .shuttingDown` in `IO.Event.Runtime.swift` first. The failing-test analysis above assumes only `register/deregister/shutdown` touch it. Verify before removing. |
| The actor still has stored properties (e.g. `executor` reference) — could those have the same bug? | `executor` is `let`, set once in init, never written. Reads are safe even with the unidentified compiler quirk. Only `var` fields written by one thread and read by another are at risk. |

### What is *not* changed

- `IO.Event.Loop.enqueue()` still has the inline fallback. We are not
  removing Fix A — we are making it unnecessary on the failure path
  while keeping it as the safety net.
- `IO.Event.Runtime` is still an actor. It still owns the driver, the
  registrations, and the integrated event loop. The only thing it loses
  is lifecycle state.
- `IO.Event.Selector.Scope` is unchanged. `~Copyable, ~Escapable`,
  consuming `close()`, etc.
- The public `IO.Event.Selector` API surface is unchanged. `register()`,
  `deregister()`, `rearm()` retain their signatures.
- The Tier 0 user-facing API (`IO.run`, `IO.Stream`) is completely
  unchanged. The slip is an internal implementation detail of `IO.Event.Selector`.

## Open Questions

These need a parent decision, not just my judgment.

### Q1: Should the slip be `~Escapable` as well as `~Copyable`?

Adding `~Escapable` would prevent storing the slip in a field for
later use. Currently the slip is `~Copyable, Sendable` and the natural
shape is "obtain → consume immediately". `~Escapable` is incompatible
with `Sendable` (cannot send a non-escapable across isolation
boundaries), so the slip must travel from `Selector.register()`
(non-isolated) into `runtime.register(...)` (actor-isolated) — that
crossing requires `Sendable`.

**Recommendation**: Stay with `~Copyable, Sendable`. The compile-time
single-use guarantee from `~Copyable` is sufficient. `~Escapable`
would over-constrain.

### Q2: Should `Loop.requestShutdown()` be `consuming` on the lifecycle field?

Currently proposed as a regular method. Could be a one-shot using
`Atomic.compareExchange` so that calling it twice is detected.

**Recommendation**: Keep simple. `Runtime.shutdown()` already has its
own once-only guard (`guard state == .running else { return false }`).
Replace that with `guard !lifecycle.exchange(1, ordering: .acqrel)`. If
the compare-exchange returns 1, shutdown was already requested; return
`false`. This is a one-line change and removes the last `var state` reference.

### Q3: Should the slip be parameterised by the Loop instance?

A phantom type parameter `AdmissionSlip<Loop: IO.Event.Loop>` would
prevent passing a slip from one Loop to another's actor. This is
defensive — currently there is no path that confuses Loops because
`Selector.register` calls `executor.admit()` and immediately passes
the result to `runtime.register`, both of which reference the same Loop
via the Selector.

**Recommendation**: Not needed for v1. Add only if a multi-Loop test
ever introduces a real risk.

### Q4: Is the SIGSEGV mentioned in the handoff related?

The handoff says "Release mode: three failures + SIGSEGV elsewhere
that may or may not be related." I did not investigate the SIGSEGV
in this proposal. **Recommendation**: Treat as a separate investigation.
If it disappears after applying this fix, log it. If it persists,
hand off separately.

### Q5: Should we file a Swift compiler bug report?

If reproducing in isolation succeeds (e.g. via further reduction of
swift-io), upstream this. If not, leave it as an internal note —
the structural fix removes our exposure regardless.

**Recommendation**: Time-box one focused attempt at reduction (4
hours), then either file or move on. The structural fix is independent.

### Q6: What about the `arm()` actor method, which doesn't take a slip?

`arm()` is fire-and-forget — even today it absorbs errors silently
("an arm failure surfaces as a missing event, which the channel's
retry loop will handle"). It is correct for `arm()` to be a no-op
post-shutdown without needing admission control. No slip needed.

`publish()` and `deregisterForgotten()` are similar — fire-and-forget
internal helpers that should not throw on shutdown. They stay
slipless.

The slip is only required for **operations the caller observes the
result of and that should distinguish "shutdown" from "leaf error"**.
That is precisely `register` and `deregister`.

## Findings (summary)

Bug confirmed reproducible in `swift test -c release -Xswiftc -Xllvm
-Xswiftc -sil-disable-pass=CopyPropagation`. Three Shutdown tests fail
with `Failure: Invalid descriptor` instead of `shutdownInProgress`.

Bug **not** reproducible in a minimal isolated experiment
(`Experiments/actor-state-cross-thread-inline/`). 1003 attempts across
five variants — 0 bug observations. The minimal pattern (custom serial
executor + actor + inline fallback + cross-thread state read) is
insufficient to trigger the failure. The bug requires something
specific to swift-io's exact compiler-input shape — most likely the
combination of WMO, the `-sil-disable-pass=CopyPropagation` flag (which
is itself a workaround for an unrelated SIL crash), and the actor's
multi-step register body.

Because the precise compiler interaction is not pinned down, the only
safe response is to **eliminate the actor-isolated lifecycle load
entirely** rather than to trust it under release-mode optimisation.
The proposed fix (option D) does this via an `AdmissionSlip` type that
is `~Copyable, Sendable`, mintable only by `Loop.admit()` (a synchronous
atomic load), and consumed by the actor method on entry. The compiler
enforces single-use; the `Atomic<UInt8>` provides explicit memory
ordering; the lifecycle state lives on the Loop (which owns the lifecycle)
not on the Runtime actor.

This is more refactor-proof than options B and C in the handoff
because the type system enforces the contract: a future operation
that needs admission control naturally requires a slip parameter, and
forgetting to call `executor.admit()` is a compile error rather than a
silent regression. There is no `state` field for any future read to
mis-cache.

Migration is bounded: ~80 lines across 4 files, no public API change,
no test changes for the structural fix itself. The remaining risk
(in-flight race window) is unchanged from today and acceptable.

## References

- [HANDOFF-actor-state-visibility-fix.md](../HANDOFF-actor-state-visibility-fix.md) — investigation brief
- [executor-first-architecture.md](executor-first-architecture.md) — Phase 3 completion notes; the integrated event loop pattern this builds on
- [completion-queue-ownership-redesign.md](completion-queue-ownership-redesign.md) — "ownership subsumes synchronization" precedent
- [perfect-lifecycle-design.md](perfect-lifecycle-design.md) — lifecycle visibility at the boundary
- `Experiments/actor-state-cross-thread-inline/` — minimal repro attempt (negative result)
- `IO.Event.Runtime.swift:39` — current `state: State = .running` field (to be removed)
- `IO.Event.Runtime.swift:88` — current `register()` body with `guard state == .running` (to be replaced)
- `IO.Event.Loop.swift:149` — current `enqueue()` inline fallback (kept; safety net)
- `IO.Event.Selector.swift:105` — current `register()` body (to add `executor.admit()`)
- `IO.Event.Selector.Shutdown.Tests.swift:36/127/178` — the three failing tests
- `feedback_test_hang_timeouts.md` (memory) — Fix A history; explains why we can't simply delete the inline fallback
- `project_optimize_none_bug.md` (memory) — the underlying SIL crash that forces the `-sil-disable-pass` flag
