# io-bench Pattern Audit

<!--
---
version: 1.0.0
last_updated: 2026-03-20
status: IN_PROGRESS
tier: 1
---
-->

## Context

Discovery audit of `swift-io/Benchmarks/io-bench/` to inventory less-than-ideal patterns before codifying the benchmark-implementation skill. Per [RES-013], this is a systematic evaluation of implementation decisions against ecosystem conventions.

**Trigger**: [RES-012] Proactive quality check before promoting patterns to a skill.
**Scope**: [RES-002a] Package-specific — io-bench only.

## Inventory

### F-01: `try!` on `Kernel.Thread.Count` literals

**Files**: IOFixture.swift:19, Lifecycle Benchmarks.swift:31/41, Backpressure Benchmarks.swift:82, Cancellation Benchmarks.swift:38/114, Memory Benchmarks.swift:86

**Pattern**: `try! Kernel.Thread.Count(4)` scattered as inline literals.

**Problem**: `try!` obscures intent and scatters initialization logic. Thread counts are always valid small constants (2 or 4) — the `try` can never fail.

**Fix**: Define `static let` constants (e.g., `static let workers: Kernel.Thread.Count = 4` via a helper that hides the `try!` in one place) or add a test-only literal conformance.

---

### F-02: `@unchecked Sendable` on fixture classes

**Files**: Backpressure Benchmarks.swift:54 (`SaturatedLaneFixture`), Cancellation Benchmarks.swift:21 (`FilledQueueFixture`)

**Pattern**: `final class Foo: @unchecked Sendable` with mutable `blockerTasks` array.

**Problem**: Bypasses concurrency verification. The array is only mutated during initialization (before the fixture is shared), so it's safe in practice, but the compiler can't verify this.

**Fix**: Make `blockerTasks` a `let` by collecting them in `saturate()` and returning them to `init`, or use `nonisolated(unsafe)` on the specific property.

---

### F-03: `DispatchSemaphore` for async→sync bridging

**Files**: Backpressure Benchmarks.swift:61, Cancellation Benchmarks.swift:27

**Pattern**: `static let shared` initializer uses `DispatchSemaphore` to block until async setup completes.

**Problem**: Known potential for deadlock if the cooperative thread pool is exhausted. Works here because the Task is lightweight, but fragile. Also requires `import Foundation`.

**Fix**: Investigate whether a `Kernel`-level blocking primitive or an `UnsafeContinuation`-based approach can replace this. Alternatively, make fixture initialization `async` and call from a suite-level setup.

---

### F-04: `import Foundation` in benchmark files

**Files**: Backpressure Benchmarks.swift:9, Cancellation Benchmarks.swift:9

**Pattern**: Foundation imported for `Thread.sleep(forTimeInterval:)` (in `BlockerLatch`) and `DispatchSemaphore` (in fixtures).

**Problem**: Foundation is discouraged in the ecosystem. Two distinct usages pull it in.

**Fix**: Replace `Thread.sleep` with a system-level sleep (e.g., `usleep` via Darwin/Glibc, or `Kernel.Thread.sleep`). Resolving F-03 would eliminate the semaphore dependency.

---

### F-05: Hardcoded magic numbers

**Files**: All benchmark files.

**Pattern**: Thread counts (`2`, `4`), queue limits (`16`, `64`, `128`, `1000`, `4000`), operation counts (`32`, `100`, `400`, `1000`, `2000`), work durations (`.microseconds(10)`, `.milliseconds(1)`) appear as inline literals.

**Problem**: Undiscoverable, hard to tune, unclear intent. Changing the thread count for a comparison run requires editing multiple files.

**Fix**: Define named constants as `static let` on each Performance extension. Group related parameters (e.g., `struct Config { static let workers = 4; static let ops = 1000; static let workDuration = Duration.microseconds(10) }`).

---

### F-06: Inconsistent fixture patterns — five approaches in one package

**Files**: All benchmark files.

| File | Pattern |
|------|---------|
| Throughput, Overhead, Allocation | `static let fixture = IOBenchmarkFixture.shared` |
| Contention | Free function `makeHighCapacityLane()` |
| Lifecycle | Inline lane creation per test |
| Backpressure | `SaturatedLaneFixture.shared` (custom class) |
| Cancellation | `FilledQueueFixture.shared` (custom class) |
| Scheduling | `static let executors = Kernel.Thread.Executors(...)` |

**Problem**: Six fixture patterns in one package. No consistent convention for "how do benchmarks get their resources."

**Fix**: Establish a fixture taxonomy: (1) shared singleton for steady-state, (2) per-test creation for lifecycle measurement, (3) pre-configured fixture for special states. All should be `static let` on the Performance suite, not free functions or external classes.

---

### F-07: Duplicated concurrent TaskGroup boilerplate

**Files**: Throughput, Contention, Backpressure, Memory benchmarks.

**Pattern**: Nearly identical 8-line `withThrowingTaskGroup` pattern repeated ~8 times:
```swift
try await withThrowingTaskGroup(of: T.self) { group in
    for _ in 0..<N {
        group.addTask { try await lane.run(...) { work } }
    }
    for try await _ in group {}
}
```

**Problem**: Repetitive, obscures what varies between benchmarks (count, work duration).

**Fix**: Extract a helper like `runConcurrent(on:count:work:)` that encapsulates the TaskGroup pattern. Each benchmark call becomes one line.

---

### F-08: Inconsistent `Result` consumption patterns

**Files**: Throughput, Overhead, Memory benchmarks.

| Pattern | Where |
|---------|-------|
| `_ = result` | Throughput sequential (line 40) |
| `switch result { case .success(let value): return value }` | Throughput/Memory concurrent |
| `withExtendedLifetime(result) {}` | Overhead, Memory single-op |
| `let _: Result<Void, Never> = try await ...` (discarded) | Contention, Backpressure |

**Problem**: Four different patterns for consuming `Result<T, Never>`. No consistent convention.

**Fix**: Pick one. `withExtendedLifetime(result) {}` is the most correct for preventing the optimizer from eliding the operation. Standardize on it.

---

### F-09: `SaturatedLaneFixture` duplicates `threadCount`/`queueLimit`

**File**: Backpressure Benchmarks.swift:79-80 and 95-96

**Pattern**: `init()` and `saturate()` both declare local `let threadCount = 2`, `let queueLimit = 1`.

**Problem**: Same constants defined in two places. Easy to diverge during edits.

**Fix**: Make them `static let` or stored properties on the fixture.

---

### F-10: `BlockerLatch` spin-waits with 100µs `Thread.sleep`

**File**: Backpressure Benchmarks.swift:33

**Pattern**: `Thread.sleep(forTimeInterval: 0.0001)` in a tight while-loop.

**Problem**: Burns CPU in 100µs increments. On benchmark machines, this consumes a core and can affect measurement stability. A proper condition variable or futex wait would be more efficient.

**Fix**: Use `Kernel.Thread.Synchronization` condvar or `pthread_cond_wait` instead of spin-sleep.

---

### F-11: Nested `do-do` in saturation verification

**File**: Backpressure Benchmarks.swift:133-149

**Pattern**: Nested `do { do { ... } catch { ... } ... }` blocks for probing saturation state.

**Problem**: The outer `do` serves no purpose — it doesn't catch anything. Confusing control flow carried from original code.

**Fix**: Flatten to a single `do-catch` with the sleep at the end.

---

### F-12: Unused `completed` variable

**File**: Backpressure Benchmarks.swift:212-213

**Pattern**: `var completed = 0` incremented but never read. Only `rejected` is checked.

**Problem**: Dead code.

**Fix**: Remove `completed` counter. Use only `rejected`.

---

### F-13: File name / enum name mismatch

**File**: `Memory Benchmarks.swift` contains `enum Allocation`.

**Problem**: Per [TEST-009], file naming should mirror the type hierarchy. `Memory Benchmarks.swift` → `Allocation` is a mismatch.

**Fix**: Either rename file to `Allocation Benchmarks.swift` or rename enum to `Memory`.

---

### F-14: `@testable import IO` in Scheduling benchmarks

**File**: Scheduling Latency Benchmarks.swift:10

**Pattern**: Uses `@testable import IO` to access `Kernel.Thread.Executors` — an internal type.

**Problem**: Benchmarks should measure public API. If executors scheduling is worth benchmarking, the type should be public. `@testable` also breaks in release mode.

**Fix**: Either make `Kernel.Thread.Executors` public, or remove this benchmark until the API is stabilized.

---

### F-15: Contention benchmarks include lifecycle overhead in measurement

**Files**: Contention Benchmarks.swift:32-47, 49-64, 68-83

**Pattern**: Each contention test creates a lane via `makeHighCapacityLane()`, does work, then calls `await lane.shutdown()`. `.timed()` measures the full cycle.

**Problem**: Lifecycle cost (lane creation + thread spawning + shutdown) is included in what's supposed to be a contention measurement. Throughput benchmarks correctly use a shared fixture.

**Fix**: Create a shared high-capacity lane fixture (similar to `IOBenchmarkFixture.shared` but with unbounded queue config). Contention tests use it for steady-state measurement.

---

### F-16: No `.gitignore` in `Benchmarks/` for sub-package artifacts

**Pattern**: `.build/` and `.swiftpm/` and `.benchmarks/` are handled by the parent `.gitignore`, but `Benchmarks/io-bench/` and `Benchmarks/nio-bench/` each have their own SPM resolution scope. `Package.resolved` files could appear.

**Fix**: Add a `Benchmarks/.gitignore` with `.build/`, `.swiftpm/`, `.benchmarks/`, `Package.resolved`.

---

## Summary

| Severity | Count | IDs |
|----------|-------|-----|
| Structural (fixture inconsistency) | 2 | F-06, F-15 |
| Correctness (dead code, duplication) | 3 | F-09, F-11, F-12 |
| Convention violations | 3 | F-04, F-13, F-14 |
| Code quality (boilerplate, magic numbers) | 3 | F-05, F-07, F-08 |
| Safety/robustness | 4 | F-01, F-02, F-03, F-10 |
| Housekeeping | 1 | F-16 |

**Total**: 16 findings.

## References

- `benchmark-implementation-conventions.md` — the research document these findings will refine
- `testing` skill — [TEST-007], [TEST-009], [TEST-015]
- `testing-institute` skill — [INST-TEST-007], [INST-TEST-011]
