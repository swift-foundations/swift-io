# Evaluation: swift-service-lifecycle for swift-io

Date: 2026-03-24
Status: COMPLETE

---

## 1. swift-service-lifecycle: What It Is

Repository: `swift-server/swift-service-lifecycle` (GitHub)
License: Apache 2.0
SSWG: **Incubating** (accepted 2020-09-02, SSWG-0015)
Current version: 2.10.1 (2026-02-20)
Last push: 2026-03-18 (actively maintained)
Maintainers: Franz Busch (primary architect), Tomer Doron, Konrad Malawski — all Apple

Swift tools version: 6.0
Platforms: macOS 10.15+, iOS 13.0+, Linux, Android. WASI/Windows limited (no signal support).

### Service Protocol

```swift
public protocol Service: Sendable {
    func run() async throws
}
```

One method. Existential throws (`throws`, not `throws(E)`). No associated types.
Run is expected to block until the service should stop. Returning or throwing triggers termination behavior.

### ServiceGroup

Actor. Itself conforms to Service (composable nesting).

```swift
public actor ServiceGroup: Sendable, Service {
    public init(services: [any Service], gracefulShutdownSignals: [UnixSignal] = [],
                cancellationSignals: [UnixSignal] = [], logger: Logger)
    public func run() async throws
    public func triggerGracefulShutdown() async
    public func addServiceUnlessShutdown(_ service: any Service) async
}
```

Run behavior:
1. Validates state (`.initial` → `.running`).
2. Sets up `UnixSignalsSequence` for graceful shutdown and cancellation signals.
3. Spawns one child task per service in a `ThrowingTaskGroup`, each wrapped with its own `GracefulShutdownManager` via `@TaskLocal`.
4. Waits on `group.next()` for service completions or signal events.

Shutdown ordering: **reverse registration order** (LIFO). Each service is signalled individually via `GracefulShutdownManager.shutdownGracefully()`, then the group waits for that service's `run()` to return before proceeding to the next.

Termination behavior per service: `.cancelGroup` (default), `.gracefullyShutdownGroup`, `.ignore`.

Escalation chain: graceful shutdown → (timeout) → task cancellation → (timeout) → `fatalError()`.

### Graceful Shutdown Mechanism

TaskLocal-based. Services opt in via:

```swift
try await withGracefulShutdownHandler {
    // long-running operation
} onGracefulShutdown: {
    // synchronous handler: @Sendable @escaping () -> Void
}
```

The handler is **synchronous**. Cannot call `async` methods. Designed for setting atomic flags, signaling conditions, cancelling listeners — not for performing async cleanup.

`gracefulShutdown()` — suspends until graceful shutdown is triggered.
`cancelWhenGracefulShutdown(_:)` — cancels the operation when shutdown arrives.
`Task.isShuttingDownGracefully` — check current state.

### Unix Signal Handling

Separate product: `UnixSignals`. Uses `DispatchSource.makeSignalSource()` internally.
On Darwin, calls `signal(sig, SIG_IGN)` before installing dispatch source (kqueue precedence).
Supports: SIGTERM, SIGINT, SIGHUP, SIGUSR1/2, SIGALRM, SIGQUIT, SIGWINCH, SIGCONT, SIGPIPE + abort/ill/segv.
Single iterator per sequence enforced.

---

## 2. Dependency Analysis

### Direct Dependencies

| Package | Version | License | Foundation? |
|---------|---------|---------|-------------|
| swift-log | >= 1.5.2 | Apache 2.0 | No |
| swift-async-algorithms | >= 1.1.3 | Apache 2.0 | No |

### Full Transitive Tree (resolved)

```
swift-service-lifecycle
├── swift-log (1.10.1)
├── swift-async-algorithms (1.1.3)
│   └── swift-collections (1.4.1)
├── UnixSignals (internal target, uses Dispatch)
└── ConcurrencyHelpers (internal target, pure pthread)
```

Three external packages. Zero Foundation imports anywhere in the library.

### Platform Library Dependencies

| Module | Platform Library |
|--------|-----------------|
| UnixSignals | `Dispatch` (DispatchSource for signal handling) |
| ConcurrencyHelpers | `Darwin`/`Glibc`/`Musl` (pthread_mutex) |

ConcurrencyHelpers is a `LockedValueBox` + `Lock` implementation copied verbatim from SwiftNIO.

### Comparison with swift-io's Current Dependencies

swift-io depends on **Layer 1 primitives only**: Kernel, Async, Ownership_Primitives, Dictionary_Primitives, Synchronization, Buffer_Primitives, Heap_Primitive, Memory_Pool_Primitives, IO_Core.

Zero external ecosystem packages. Zero Dispatch. Zero Foundation.

Adding swift-service-lifecycle would introduce:
- 3 external packages (swift-log, swift-async-algorithms, swift-collections)
- Dispatch (via UnixSignals)
- A dependency on the SSWG ecosystem

---

## 3. Architectural Fit Analysis

### 3.1 Does Service.run() Map onto IO.Event.Selector?

**Partially, with friction.**

Selector's lifecycle is:
- `make()` → creates actor, spawns poll thread, starts `runEventLoop()` + `runReplyLoop()` tasks
- (selector is running — no single blocking method)
- `shutdown()` → signals poll thread, drains waiters/replies, joins poll thread

The Service protocol requires a single `run()` that blocks until the service should stop. Selector has no such method. A conformance would need a synthetic blocking point:

```swift
// Hypothetical — not a recommendation
extension IO.Event.Selector: Service {
    public func run() async throws {
        try await withGracefulShutdownHandler {
            try await gracefulShutdown()  // suspends until ServiceGroup signals shutdown
        } onGracefulShutdown: {
            // Need to signal selector synchronously
            topology.shutdownFlag.set()
            topology.wakeupChannel.wake()
        }
        await shutdown()  // async: drain waiters, join poll thread
    }
}
```

This works mechanically because:
- `topology` is `nonisolated let` on the actor — accessible without actor hop
- `shutdownFlag.set()` and `wakeupChannel.wake()` are synchronous (`@Sendable () -> Void` compatible)
- The actual async cleanup happens after the handler fires

**Friction points:**
- `topology` is internal — conformance must live inside the swift-io module
- The Service protocol uses existential `throws`, violating [API-ERR-001]
- Selector doesn't naturally "run" — it's created and used, then explicitly shut down
- The `make() → use → shutdown()` lifecycle is fundamentally different from `run()`

### 3.2 Is ServiceGroup Compatible with the Dedicated Poll Thread?

**Yes, with indirection.**

ServiceGroup manages child tasks within a `ThrowingTaskGroup`. Swift structured concurrency's cancellation propagates to child tasks. But the poll thread is a POSIX thread outside the cooperative pool — it doesn't respond to task cancellation.

The bridge is the same as the conformance above: cancellation → handler fires → `shutdownFlag.set()` → poll thread sees flag and exits.

This is exactly how NIO frameworks bridge: the framework's `Service.run()` calls `withGracefulShutdownHandler`, and the handler signals the NIO event loop group via `shutdownGracefully()`.

### 3.3 Does It Solve Problem #2 (Singleton Shutdown)?

**Not directly.** `Selector.shared()` is process-scoped with no shutdown path. ServiceGroup runs within a scope. Registering the shared singleton as a service would mean shutting it down when the ServiceGroup stops — but other parts of the process might still need it.

Options:
- (a) Don't use the singleton with ServiceGroup — create a scoped selector per ServiceGroup
- (b) Add an optional shutdown path to the singleton that ServiceGroup can trigger

Neither requires swift-service-lifecycle as a dependency. A `withSelector { }` scoped API solves this more naturally (see Section 5).

### 3.4 Does It Solve Problem #3 (Subsystem Degradation Notification)?

**Partially.** Per-service `TerminationBehavior` controls what happens when a service's `run()` throws:
- `.cancelGroup` → cancels all other services
- `.gracefullyShutdownGroup` → triggers graceful shutdown of all other services
- `.ignore` → nothing

If the selector's `run()` throws because the poll thread died (fatal error propagated via `emergencyDrain()`), the ServiceGroup would cancel or shut down dependent services. Higher layers are notified by being cancelled.

**Limitation:** No restart capability. ServiceGroup is one-way (running → finished). No equivalent to a supervision tree that restarts failed children.

### 3.5 Does It Solve Problem #4 (Shutdown Ordering)?

**Yes, if services are registered in the correct order.** Reverse-order shutdown means:

```swift
ServiceGroup(services: [
    selectorService,      // registered first, shut down last
    channelManagerService, // registered second, shut down second
    applicationService,   // registered last, shut down first
], ...)
```

Application shuts down first (closes connections gracefully), then channel manager (closes remaining channels), then selector (drains poll thread).

This requires modeling each layer as a separate `Service`, which adds structural overhead but makes the ordering explicit.

### 3.6 Does It Handle Channels (Problem #5)?

**No.** swift-service-lifecycle manages services, not resources. There is no concept of a "managed resource" that is scoped to a service's lifetime.

Channels are resources owned by code running within a service. Their cleanup is the caller's responsibility. This is the same model used by Vapor/Hummingbird: channels and connections are managed by the server service, not by ServiceGroup.

The channel lifetime problem (no `withChannel { }`, no task-cancellation integration) must be solved at the swift-io level regardless of whether ServiceGroup is adopted.

---

## 4. SwiftNIO Precedent

**SwiftNIO does NOT depend on swift-service-lifecycle.** Its only external dependencies are swift-atomics, swift-collections, swift-system.

NIO defines its own lifecycle via `EventLoopGroup.shutdownGracefully()`:
- Callback-based (`(Error?) -> Void`), not structured concurrency
- Idempotent (multiple calls safe, later callers queued)
- Joins POSIX threads
- No signal handling — left to the application
- Async extension added via `withCheckedThrowingContinuation` bridge

The integration point with `Service` protocol is at the **framework level** (Layer 4+):
- Vapor's `Application` conforms to `Service`
- Hummingbird's `HBApplication` conforms to `Service`
- Both use `ServerQuiescingHelper` from swift-nio-extras to bridge shutdown signals to NIO channels
- Both call `eventLoopGroup.shutdownGracefully()` inside their `withGracefulShutdownHandler` block

**Pattern:** Low-level I/O layer defines its own shutdown primitive. Frameworks bridge that primitive to the Service protocol. This is the established ecosystem pattern.

---

## 5. Alternatives Assessment

### 5.1 Adopt swift-service-lifecycle as a Dependency

**Against.**

Costs:
- 3 new external packages (swift-log, swift-async-algorithms, swift-collections)
- Dispatch dependency via UnixSignals
- Existential throws on `Service.run()` violates [API-ERR-001]
- Locks swift-io into the SSWG ecosystem's release cadence
- swift-io currently depends only on L1 primitives — this would be the first L3-on-external dependency

Benefits:
- Standardized shutdown protocol recognized across the Swift server ecosystem
- Built-in signal handling
- Built-in reverse-order shutdown orchestration

**Verdict:** The costs outweigh the benefits. swift-io is a low-level I/O primitive (analogous to SwiftNIO's NIOPosix). The ecosystem pattern is for low-level layers to define their own shutdown mechanism and for higher layers to bridge to ServiceGroup.

### 5.2 Define Own Service-like Protocol

**Against at Layer 3. Possibly at Layer 1 if demand materializes.**

A minimal protocol:

```swift
public protocol Runtime: Sendable {
    associatedtype Failure: Error
    func run() async throws(Failure)
}
```

This would give typed throws but create a parallel protocol to swift-service-lifecycle's `Service`. Consumers needing both would have to bridge between them. The value proposition is low unless multiple Layer 3 packages need the same pattern.

If this becomes a cross-cutting concern (multiple foundations packages need lifecycle management), it should be defined at Layer 1 as a primitives protocol. But only when demand is demonstrated, not speculatively.

### 5.3 Scoped `withSelector { }` API

**Recommended as the primary solution.**

```swift
// Conceptual API shape — not final
extension IO.Event.Selector {
    public static func withSelector(
        executor: Kernel.Thread.Executor,
        _ body: (IO.Event.Selector) async throws(some Error) -> T
    ) async throws(some Error) -> T
}
```

How it works:
1. Creates selector via `make()`.
2. Runs `body(selector)` within `withTaskCancellationHandler`.
3. On normal return: calls `shutdown()`, returns result.
4. On throw: calls `shutdown()`, rethrows.
5. On task cancellation: the cancellation handler synchronously signals `shutdownFlag.set()` + `wakeupChannel.wake()`. The poll thread exits. `shutdown()` completes the teardown. `body` sees `CancellationError` from its next suspension point.

What this solves:
- **Problem #2** (singleton shutdown): The selector's lifetime is scoped. When the scope exits, the selector is shut down. No singleton needed for this pattern.
- **Problem #4** (shutdown ordering): Structured concurrency's scope nesting provides natural ordering. An outer scope (selector) outlives inner scopes (channels).
- **Problem #5** (channel lifetime): A corresponding `withChannel { }` scope composes naturally inside `withSelector { }`.

What it doesn't solve:
- Signal handling (application responsibility, or Layer 4+)
- Multi-service orchestration (ServiceGroup's domain)
- Cross-service shutdown ordering (ServiceGroup's domain)

Implementation notes:
- `topology` is already `nonisolated let` and `Sendable` — the cancellation handler can access `shutdownFlag` and `wakeupChannel` synchronously.
- `topology` is internal — the scoped API lives inside the swift-io module. External consumers access it through the public `withSelector` function.
- No new dependencies required.

### 5.4 Do Nothing

**Against.** The lifecycle problems are real (documented in io-event-selector-timed-hang.md and io-event-channel-hardening.md). The singleton has no shutdown path. Channels leak on error paths. Doing nothing leaves these problems for every consumer to solve independently.

---

## 6. Recommendation

### Primary: Scoped API Pattern (Layer 3)

Implement `withSelector { }` and `withChannel { }` scoped APIs at Layer 3. These use structured concurrency directly, require no new dependencies, and solve the core lifetime management problems (#2, #4, #5).

The scoped APIs should:
- Guarantee cleanup on all exit paths (normal return, throw, cancellation).
- Bridge task cancellation to the poll thread's shutdown flag synchronously.
- Compose: `withSelector { selector in withChannel(on: selector) { channel in ... } }`.

The existing `make()` + `shutdown()` API remains available for advanced use cases where scoped lifetime is too restrictive.

### Secondary: Layer 4 Integration (Future)

A Layer 4 (Components) package can provide the bridge between swift-io and swift-service-lifecycle:
- Defines a `IO.Service` type (or wrapper) conforming to `Service`
- Depends on both swift-io and swift-service-lifecycle
- Handles signal-to-shutdown bridging
- Provides the ServiceGroup integration pattern

This follows the established NIO ecosystem pattern exactly.

### Do Not: Depend on swift-service-lifecycle at Layer 3

The dependency cost is too high for this layer. The existential throws violation, the Dispatch dependency, and the 3 transitive packages are unjustified when the scoped API pattern solves the same problems with zero dependencies.

### Do Not: Define a competing Service protocol

Unless multiple Layer 3 packages demonstrate the need for a shared lifecycle protocol, this adds complexity without clear value. The scoped API pattern is sufficient for swift-io's needs.

---

## 7. Impact on Existing Problems

| Problem | Scoped API Impact | Service Lifecycle Impact |
|---------|-------------------|------------------------|
| #1 Channel leak on error | Solved by `withChannel { }` | Not addressed (resource, not service) |
| #2 No singleton shutdown | Avoided — scoped selector, no singleton needed | Partially — but singleton concept conflicts |
| #3 Silent poll thread death | Scoped API can rethrow from body | Partially — TerminationBehavior propagates |
| #4 Ad-hoc shutdown ordering | Solved by scope nesting | Solved by reverse registration order |
| #5 Unscoped channel lifetime | Solved by `withChannel { }` | Not addressed (resource, not service) |

The scoped API pattern addresses 4 of 5 problems. Problem #3 (poll thread resilience) is partially addressed — if the poll thread dies during a scoped operation, the error propagates through the event bridge's `.fatal(error)` → `emergencyDrain()` → continuation resumption → scoped body throws. The scoped API then cleans up and rethrows.

---

## 8. Appendix: swift-service-lifecycle Dependency Detail

### ConcurrencyHelpers

Two files, copied from SwiftNIO:
- `Lock.swift` — `pthread_mutex_t`-based lock (SRWLOCK on Windows)
- `LockedValueBox.swift` — lock-protected value with `withLockedValue(_:)` accessor

Uses `ManagedBuffer` for tail allocation of lock alongside value. No Foundation, no Dispatch.

### UnixSignals

- `DispatchSource.makeSignalSource()` for signal delivery
- Private serial `DispatchQueue` for handler serialization
- `AsyncStream` bridge from dispatch source events to async iteration
- State machine enforces single-iterator semantics

This is the **only** Dispatch dependency in the entire library.

### swift-async-algorithms Transitive

swift-async-algorithms depends on swift-collections (1.4.1). swift-collections has no further dependencies. ServiceLifecycle uses `AsyncChannel` from swift-async-algorithms for dynamic service addition (`addServiceUnlessShutdown`).

### swift-log

Pure logging facade. No transitive dependencies. Used for structured logging in ServiceGroup (startup, shutdown, errors).
