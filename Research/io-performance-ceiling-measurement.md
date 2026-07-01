# swift-io Performance Ceiling — Measurement

<!--
---
version: 1.0.0
created: 2026-04-14
status: RESOLVED
tier: 2
related:
  - swift-io/Research/io-blocking-executor-binding.md (v4.0 — Shape B)
  - swift-io/HANDOFF-io-layered-implementation-review.md
  - swift-io/HANDOFF-io-layered-implementation-review-response.md
  - swift-io/Experiments/io-stacked-actor-bench/ (source + RESULTS.md)
  - swift-io/Experiments/actor-hop-benchmark/ (precedent; no-op hop cost)
changelog:
  - v1.0: Initial measurement. Resolves Item 6 from the review advisory.
---
-->

## Question

Does Shape B's per-op actor-hop cost (~3.9 µs measured in `actor-hop-benchmark/` for a no-op actor method) constitute a structural performance ceiling for `swift-io`, or does the TCA26 shared-executor pattern actually eliminate it in realistic stacked use?

## Context

The review advisory (`HANDOFF-io-layered-implementation-review.md` § Item 6) flagged that Shape B's default-path overhead could structurally cap the performance of packages built on top of swift-io (`swift-sockets`, `swift-file-system`, `swift-pipes`). The response doc acknowledged an overreach ("swift-sockets CANNOT be tokio-competitive. Period.") and asked for empirical verification before committing to Framing E in the forthcoming `io-events-completions-fate.md`.

The prior evidence (`actor-hop-benchmark/RESULTS.md`) was a no-op microbenchmark. It proved the hop cost is real but didn't answer: **what happens when there's actual syscall work, and does the shared-executor optimization fire under realistic stacked actor use?**

## Methodology

Four-configuration measurement: `swift-io/Experiments/io-stacked-actor-bench/`.

| Config | What it measures |
|:------:|------------------|
| 1. Raw syscall | `pipe()` + `read()`/`write()` with no actor, no witness — floor reference |
| 2. Plain actor + raw syscall | Actor method delegating to POSIX syscall — isolates actor-hop cost from witness-specific cost |
| 3. Shape B IO, unshared executor | `IO.blocking(on:)` called from cooperative pool — default cross-hop path |
| 4. Shape B IO, shared executor (TCA26) | `IO.blocking(on:)` called from a consumer actor forwarding `unownedExecutor` — fast path |

Workload: single task, each iteration is `write(4KB)` + `read(4KB)` on a pipe (fits default 16KB Darwin pipe buffer, never blocks on backpressure). 50,000 iterations per trial × 3 trials, 2,000-iter warmup.

## Measurements

| Config | Mean ns/op | Throughput ops/sec |
|:------:|-----------:|-------------------:|
| 1. Raw syscall | 337 | 2.97 M |
| 2. Plain actor + syscall | 2,780 | 360 K |
| 3. Shape B IO unshared | 5,198 | 192 K |
| 4. Shape B IO shared | 320 | 3.12 M |

Derived:

| Delta | ns/op | Meaning |
|-------|------:|---------|
| Actor-hop cost (C2 − C1) | +2,443 | Cost of crossing from caller's executor to actor's executor |
| Witness overhead (C3 − C2) | +2,417 | Cost of IO's closure layer on top of the internal actor |
| Shared savings (C3 − C4) | −4,878 | TCA26 pattern elides both hops |
| **C4 ÷ C1 ratio** | **0.95×** | Shared path vs raw syscall |
| C3 ÷ C1 ratio | 15.4× | Default path vs raw syscall |

Environment: Apple M3 MacBook Air, macOS 26.2, Swift 6.3 release build.

## Findings

### 1. The TCA26 pattern works in practice

Config 4 measures **0.95× raw syscall cost** — the shared-executor optimization eliminates per-op overhead entirely. The 17 ns apparent improvement over raw is within measurement variance (cache locality of the dedicated thread).

**The hop cost is not structural.** It is payment for *not* sharing the executor. When consumer and IO share an executor, Swift's runtime executor-match check elides the hop on every `await`, and Config 4 confirms the elision fires as promised.

### 2. Shape B adds witness-specific overhead on the default path

C3 − C2 ≈ 2,417 ns means that wrapping a plain actor in the Shape B witness (closure-forwarding from `IO` struct → stored `_read` closure → `impl.read` on the internal actor) **roughly doubles** the per-op cost compared to a direct actor method. This only matters on the unshared path; on the shared path, both structures collapse to the same ~320 ns floor.

The overhead likely comes from:
- Closure call through `@Sendable (borrowing Kernel.Descriptor, Memory.Buffer.Mutable) async throws(IO.Error) -> Int`
- Extra continuation frame between the generated forwarding method and the internal actor's isolated method

This was not verified with SIL inspection; treat as hypothesis.

### 3. Default-path performance is acceptable but not competitive

On the default path (consumer does not adopt shared-executor), Shape B is 15× slower than raw syscall. For a 4KB pipe I/O that's ~5µs per op = ~190K ops/sec on one thread. For blocking I/O workloads where syscalls cost 10-100µs each (disk reads, TCP loopback, slow network), the witness overhead is 5-50% of the syscall — noticeable but not dominant. For hot-path scenarios (tight loops of small reads/writes), it is dominant.

### 4. The review's "tokio-competitive" claim

The response doc's "swift-sockets CANNOT be tokio-competitive" was overreach. Corrected claim, backed by measurement:

> swift-sockets built on Shape B and using the TCA26 shared-executor pattern throughout can reach **~3 M ops/sec per thread** with 4KB pipe payloads — same order as the raw syscall ceiling. This is in the same range as tokio's per-op overhead (~500 ns under comparable conditions). **Shape B is not a structural ceiling for swift-sockets.**
>
> swift-sockets built on Shape B *without* adopting shared-executor inherits the 15× slowdown on every call site, capping it at ~190K ops/sec. This is not competitive with modern I/O libraries.

**The bottleneck is consumer adoption of the TCA26 pattern, not swift-io's design.**

### 5. Implication for the documentation

The goal-statement of swift-io should surface this pattern as the intended use. The prior framing ("blocking I/O defaults fine, shared-executor is a micro-optimization") is incorrect — the measured data says shared-executor is the **intended path** for production use, and the default path is a convenience for casual/non-hot use.

## Decision

Framing E (see review `HANDOFF-io-layered-implementation-review-response.md` § Item 7) is safe to commit. Shape B's shared-executor fast path measured at 0.95× raw syscall cost; this clears the "≤ 2× raw" threshold by a wide margin.

Framing B (context-oriented primitives as an alternative to witnesses) is **not needed on performance grounds**. It remains a legitimate alternative on architectural grounds (exposing `IO.Events.Runtime`, `IO.Completions.Runtime` as concrete public types might serve higher-level packages better), but is no longer forced by a performance ceiling.

## Concrete handoff changes implied

1. **Update `swift-io`'s goal statement** (in the handoff + `IO.swift` doc) to name the TCA26 pattern as the canonical production use, not a micro-optimization.
2. **Update `IO.swift` doc** to include:
   > ## Performance
   >
   > Default path (`try await io.read(...)` from cooperative pool): ~5 µs per op overhead on M3/Darwin, dominated by actor cross-hop. Acceptable for blocking I/O where syscalls cost 10+ µs.
   >
   > Shared-executor path (consumer actor forwards `unownedExecutor` to `io.unownedExecutor`): ~320 ns per op overhead, same order as raw syscall. Required for latency-sensitive stacks (servers, high-throughput clients).
3. **Add a working example** in `IO.swift` doc showing the `SharedConsumer` pattern — the shared-executor forwarding idiom is the most important piece of ergonomics for users to learn.
4. **`io-events-completions-fate.md`** can commit to Framing E without performance caveats. The Selector/Runtime/Loop/Driver runtime stays internal; consumers get Shape B witness with competitive performance via TCA26.

## Open follow-ups (not blocking)

- **Hand-written IO vs `@Witness`**: Is the 2,417 ns witness overhead on the unshared path inherent to closure-forwarding, or is it specific to `@Witness` macro generation? A hand-written `IO` with direct async methods on the actor (skipping the closure layer) could resolve this. Not urgent — shared path is the target, and shared path has no measurable overhead.
- **Network syscall comparison**: The 4KB pipe read is ~700 ns total (measured as 337 ns per op × 2 ops). TCP loopback is typically 2-5 µs per syscall. Re-running the benchmark on a socketpair or real loopback socket would show how witness overhead scales with syscall cost; expect the relative overhead to drop.
- **Multi-connection / contention**: A benchmark with N consumer actors sharing one IO would expose contention on the single executor thread. Not measured here; relevant for sizing swift-sockets' thread pool strategy.
- **p99 / tail latency**: Batch timing used throughout; tail latency under sustained load would require per-op timestamps and a different measurement strategy (the 50 ns `DispatchTime.now()` overhead is 15% of C4's 320 ns, making per-op timing structurally noisy on the fast path).

## Reproduce

```bash
cd /Users/coen/Developer/swift-foundations/swift-io/Experiments/io-stacked-actor-bench
swift build -c release
.build/release/bench
```

See `Experiments/io-stacked-actor-bench/RESULTS.md` for the full table and interpretation.
