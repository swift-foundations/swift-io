# IO Benchmark Process Hang After Completion

<!--
---
version: 1.0.0
last_updated: 2026-03-24
status: RECOMMENDATION
---
-->

## Context

The `io-bench` benchmark suite (`swift-io/Benchmarks/io-bench/`) completes all 49 tests successfully within ~10 seconds, then the process hangs indefinitely and never exits. The process must be manually killed.

Three shared static singleton fixtures hold resources that outlive the test run:

| Fixture | Workers | Deadline Threads | Resource |
|---------|---------|-----------------|----------|
| `IOBenchmarkFixture.shared` | 4 | 1 | `IO.Blocking.Threads` worker pool |
| `IOBenchmarkFixture.highCapacity` | 4 | 1 | `IO.Blocking.Threads` worker pool |
| `SaturatedLaneFixture.shared` | 2 | 1 | Gate-blocked lane + `Task.detached` |
| `FilledQueueFixture.shared` | 2 | 1 | Gate-blocked lane + `Task.detached` |

**Total: 12 worker pthreads + 4 deadline manager pthreads = 16 OS threads that never terminate.**

Regular IO tests (`swift-io/Tests/`) always call `await threads.shutdown()` or `await lane.shutdown()` and exit cleanly. The benchmark fixtures use `static let shared` because `.timed()` runs the body N iterations — the fixture must persist across iterations. Swift Testing has no global teardown hook.

### Prior Fix Attempts

1. **Gate timeout**: Changed `gate.wait()` → `gate.wait(timeout: .seconds(10))` in both gate fixtures. The `Task.detached` tasks complete after 10 seconds (verified). Process still hangs — `IO.Blocking.Threads` worker pthreads remain alive.

2. **`tearDown()` methods**: Added to both gate fixtures (opens gate, cancels tasks, awaits them, shuts down lane). No reliable place to call them — `.timed()` runs the body N times, and Swift Testing has no guaranteed-last-test ordering.

3. **`Test.Benchmark.measure` alternative**: Hit Swift type inference issues with typed throws when the closure captures fixture state.

## Question

What is the architecturally correct fix — adhering to [PLAT-ARCH-*], [IMPL-*], and [API-*] — that ensures the io-bench process exits cleanly after all tests complete?

## Analysis

### 1. Root Cause (Verified)

`IO.Blocking.Threads` creates joinable pthreads via `Kernel.Thread.trap { worker.run() }` → `Kernel.Thread.create` → `ISO_9945.Kernel.Thread.create` → `pthread_create` with `nil` attributes (= joinable). Workers run an infinite loop:

```
while !isShutdown {
    lock.wait(condition: .worker)
    // dequeue and execute work
}
```

Without `shutdown()`, `isShutdown` is never set. Workers wait on the condvar forever.

The `IO.Blocking.Threads.deinit` handles shutdown correctly — sets `isShutdown`, broadcasts, joins all threads. But static variables are never deallocated during process exit, so the deinit never runs.

### 2. Hang Mechanism

`Testing.__swiftPMEntryPoint()` calls `ISO_9945.Kernel.Process.Exit.now()` (which calls `_exit()`) after tests complete. If reached, the process terminates regardless of running pthreads.

**The process hangs because `_exit()` is never reached.** Two contributing factors:

#### Factor A: Default `.tee` reporter blocks `runner.run()` return

`Testing.Configuration.Output.format` defaults to `.tee` (console + structured JSONL). The structured sink accumulates events in memory and writes to disk during `finish()` via blocking `Kernel.IO.Write.write()` inside `withCheckedContinuation`. If the write blocks, `sink.finish()` inside `runner.run()` never returns, so `run(registry:)` never returns, so `_exit()` is never reached.

```
Testing.Configuration.Output.format    →  .tee  (default)
Testing.Configuration.Output.structuredPath  →  ".build/test-results.jsonl"
```

#### Factor B: Swift async runtime exit sequencing

The Swift runtime's `_runAsyncMain()` enters an infinite cooperative queue drain loop (`_asyncMainDrainQueue()` in `CooperativeGlobalExecutor.cpp`). The main task's completion handler calls `exit(0)`. If the main task never completes (because `runner.run()` doesn't return), the drain loop runs forever.

Even if `runner.run()` does return and `_exit()` is called, the 16 alive pthreads are a resource leak. The fix should address both the hang and the leak.

#### Diagnostic Verification

Before implementing, verify the hang location:

```swift
// In Testing.Main.run(registry:)
let result = await Witness.Context.with(mode: .test) {
    await runner.run(plan, concurrency: config.concurrency)
}
print("[DEBUG] runner.run() returned")  // Does this print?
return result.hasFailures
```

If `runner.run() returned` does NOT print → hang is inside `runner.run()`, likely the structured sink's `finish()`. If it DOES print → hang is between `run(registry:)` returning and `_exit()` executing.

### 3. Prior Art Survey

| Ecosystem | Pattern | Mechanism |
|-----------|---------|-----------|
| XCTest | `class func tearDown()` | Class-level teardown after all tests in a class |
| Apple swift-testing | None | No global fixture lifecycle; tests manage own resources |
| JUnit 5 | `@AfterAll` | Static method runs after all tests in a class |
| pytest | `scope="session"` fixtures | Fixtures with `yield` torn down after all tests |
| SwiftNIO | Explicit `shutdownGracefully()` | Tests shut down event loop groups explicitly |
| Go testing | `TestMain(m)` | Custom entry point with `os.Exit(m.Run())` |

Every mature test ecosystem provides (a) session-scoped fixture lifecycle or (b) process exit guarantees. Swift Testing provides neither. The Institute's framework needs both.

### 4. Fix Options

#### Option A: Process Exit in `Testing.main()`

`Testing.main()` currently returns normally. Make it exit the process like `__swiftPMEntryPoint()` already does. `Testing.run()` remains composable (no exit call).

`Testing.Main` already imports `Kernel` (L3 unified) per [PLAT-ARCH-008]. `ISO_9945.Kernel.Process.Exit.now()` is available via the re-export chain [PLAT-ARCH-006]. No platform conditionals in consumer code.

```swift
public static func main() async {
    let hasFailures = await run(registry: Discovery.all())
    ISO_9945.Kernel.Process.Exit.now(hasFailures ? 1 : 0)
}
```

| Criterion | Assessment |
|-----------|-----------|
| Fixes hang | Yes — `_exit()` terminates regardless of threads or blocked sinks |
| Fixes resource leak | No — threads are killed, not cleaned up |
| Blast radius | Low — `Testing.run()` remains composable |
| Implementation | 1 line |
| Skill compliance | Uses platform stack correctly [PLAT-ARCH-008], [PLAT-ARCH-006] |

#### Option B: `Test.Teardown` Closure Registry

Design call-site-first per [IMPL-000]. The ideal fixture expression:

```swift
static let shared: IOBenchmarkFixture = {
    let fixture = IOBenchmarkFixture()
    Test.Teardown.register { await fixture.shutdown() }
    return fixture
}()
```

Reads as intent [IMPL-INTENT]: "register a teardown that shuts down the fixture." No protocol — just a closure registration point. Uses existing `postRunActions` infrastructure [IMPL-060]. No premature abstraction [PATTERN-013].

Infrastructure: one new file in swift-tests per [API-IMPL-005], following [API-NAME-001] `Nest.Name`:

```swift
// Test.Teardown.swift
extension Test {
    public enum Teardown {
        nonisolated(unsafe) static var actions: [@Sendable () async -> Void] = []

        public static func register(_ action: @Sendable @escaping () async -> Void) {
            actions.append(action)
        }

        static func drain() async {
            for action in actions { await action() }
            actions.removeAll()
        }
    }
}
```

Wiring in `Testing.Main.run(registry:)`:

```swift
runner.postRunActions.append {
    await Test.Teardown.drain()
}
```

| Criterion | Assessment |
|-----------|-----------|
| Fixes hang | Yes — threads shut down before exit |
| Fixes resource leak | Yes — proper cleanup |
| Blast radius | Low — ~15 lines new code, 3 lines wiring |
| Implementation | One file + one registration per fixture |
| Skill compliance | [IMPL-000] call-site-first, [IMPL-INTENT], [IMPL-060] uses existing infra, [PATTERN-013] no protocol, [API-NAME-001] `Test.Teardown`, [API-IMPL-005] one type per file |

#### Option C: Daemon Thread Mode for `IO.Blocking.Threads`

Add `daemon: Bool` to `IO.Blocking.Threads.Options`. Daemon workers are detached pthreads.

| Criterion | Assessment |
|-----------|-----------|
| Fixes hang | Partially — doesn't fix structured sink blocking |
| Fixes resource leak | No — threads run until process death |
| Blast radius | High — changes core IO infrastructure |
| Skill compliance | Breaks `~Copyable` Handle semantics (no join for detached) |

**Rejected**: High blast radius, doesn't address the primary hang mechanism, breaks the Handle ownership model.

#### Option D: Suite-Scoped Fixture Lifecycle Provider

Add a scope provider to swift-tests that wraps suite execution with setup/teardown.

| Criterion | Assessment |
|-----------|-----------|
| Fixes hang | Yes |
| Fixes resource leak | Yes |
| Blast radius | Medium-high — new scope provider + fixture protocol |
| Skill compliance | Violates [PATTERN-013] — protocol before 3+ conformers |

**Deferred**: Architecturally elegant but premature. Consider for swift-tests v2 if session-scoped fixtures become a common pattern across multiple packages.

#### Option E: `atexit` Handler in Fixture Initialization

Register synchronous shutdown in `atexit()` during fixture creation.

**Rejected**: Known SIGBUS issue with Swift `atexit` (documented in `swift-tests/Research/atexit-sigbus-inline-snapshot-writeback.md`). `atexit` closures cannot be `async`, but `shutdown()` is `async`. Unreliable.

### 5. Comparison

| Criterion | A: Exit | B: Teardown Registry | C: Daemon | D: Suite Scope |
|-----------|:-------:|:---------------------:|:---------:|:--------------:|
| Fixes hang | ✓ | ✓ | Partial | ✓ |
| Proper resource cleanup | ✗ | ✓ | ✗ | ✓ |
| Implementation size | 1 line | ~15 lines | High | High |
| Blast radius | Low | Low | High | Medium-High |
| [IMPL-000] call-site-first | n/a | ✓ | n/a | ✓ |
| [PATTERN-013] no premature abstraction | ✓ | ✓ | ✓ | ✗ |
| [PLAT-ARCH-008] platform stack | ✓ | n/a | ✗ | n/a |
| [IMPL-060] uses existing infra | ✓ | ✓ | ✗ | ✗ |

## Outcome

**Status**: RECOMMENDATION

### Recommended: A + B (Two-Pronged)

**Layer 1 — Process exit in `Testing.main()` (Option A)**

Add `_exit()` to `Testing.main()` to match `__swiftPMEntryPoint()`. This is a 1-line change using the platform stack correctly — `ISO_9945.Kernel.Process.Exit.now()` available via `import Kernel` re-export chain [PLAT-ARCH-006], [PLAT-ARCH-008]. `Testing.run()` remains composable.

The omission of `_exit()` from `Testing.main()` is a bug, not a design choice — it's the same entry point semantics as `__swiftPMEntryPoint()`.

**Layer 2 — `Test.Teardown` registry (Option B)**

Add `Test.Teardown` to swift-tests. Designed call-site-first [IMPL-000]:

```swift
Test.Teardown.register { await fixture.shutdown() }
```

Reads as intent [IMPL-INTENT]. No protocol [PATTERN-013]. Uses existing `postRunActions` [IMPL-060]. One type per file [API-IMPL-005]. `Test.Teardown` follows `Nest.Name` [API-NAME-001].

Process exit via `_exit()` is the safety net. `Test.Teardown` is the proper cleanup mechanism. Both are needed — `_exit()` handles cases where teardown is forgotten or incomplete; teardown handles proper resource reclamation.

### Implementation Order

1. Apply **Option A** — 1 line in `Testing.Main.swift`, unblocks io-bench immediately
2. Implement **Option B** — `Test.Teardown` in swift-tests, wire into `Testing.Main.run()`
3. Register teardowns in io-bench fixtures (1 line per fixture)
4. Verify io-bench exits cleanly with both mechanisms

### Deferred

- **Option C** (daemon threads): Independent value for production use cases. Separate research.
- **Option D** (suite-scoped fixtures): Reconsider when 3+ packages need session-scoped fixtures [PATTERN-013].

## References

- `swift-io/Sources/IO Blocking Threads/IO.Blocking.Threads.swift:39-48` — deinit with shutdown
- `swift-io/Sources/IO Blocking Threads/IO.Blocking.Threads.Runtime.Start.swift:35-39` — `Kernel.Thread.trap` thread creation
- `swift-io/Benchmarks/io-bench/IO Performance Tests/SaturatedLaneFixture.swift` — gate fixture
- `swift-io/Benchmarks/io-bench/IO Performance Tests/FilledQueueFixture.swift` — gate fixture
- `swift-io/Tests/Support/IOBenchmarkFixture.swift` — thread pool fixture
- `swift-testing/Sources/Testing/Testing.Main.swift:26-29` — `__swiftPMEntryPoint` with `_exit()`
- `swift-testing/Sources/Testing/Testing.Main.swift:60-62` — `main()` without `_exit()`
- `swift-testing/Sources/Testing/Testing.Configuration.swift:68-76` — default `.tee` format
- `swift-testing/Sources/Testing/Testing.Configuration.Output.swift:29-31` — `.tee` and structuredPath defaults
- `swift-tests/Sources/Tests Performance/Test.Runner.swift:55` — `postRunActions`
- `swift-iso-9945/Sources/ISO 9945 Kernel/ISO 9945.Kernel.Process.Exit.swift:61-63` — `_exit()` wrapper
- `swiftlang/swift/stdlib/public/Concurrency/Task.swift:978-1002` — `_runAsyncMain` with `exit(0)`
- `swiftlang/swift/stdlib/public/Concurrency/CooperativeGlobalExecutor.cpp:272-278` — infinite drain loop
