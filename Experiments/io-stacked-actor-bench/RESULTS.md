# IO Stacked Actor Benchmark — Results

> Resolves Item 6 from `HANDOFF-io-layered-implementation-review.md`:
> does swift-io's actor-hop cost survive realistic stacked use?

## Hardware & Software

- **Chip**: Apple M3 (8 cores: 4P + 4E)
- **Memory**: 24 GB
- **OS**: macOS 26.2 (build 25C56)
- **Swift**: 6.3 (Apple Swift `swiftlang-6.3.0.123.5`), arm64-apple-macosx26.0
- **Build**: `swift build -c release`
- **Workload**: pipe(2) create; each iteration = 1× `write(4096)` + 1× `read(4096)` on pipe; message fits in 16KB default Darwin pipe buffer
- **Iterations**: 50,000 per trial × 3 trials; 2,000-iter warmup

## Results

| Config | Description | Mean ns/op | Min | Max | Throughput |
|:------:|-------------|-----------:|----:|----:|-----------:|
| 1 | Raw `pipe/read/write` syscalls, main task | **337.2** | 265.7 | 449.1 | 2.97 M/s |
| 2 | Plain actor pinned to `Kernel.Thread.Executor`; direct syscalls | **2,780.4** | 2,760.1 | 2,818.2 | 360 K/s |
| 3 | Shape B `IO.blocking(on:)`, called from cooperative pool (cross-hop) | **5,197.5** | 5,163.1 | 5,216.4 | 192 K/s |
| 4 | Shape B `IO.blocking(on:)`, called from `SharedConsumer` actor forwarding `unownedExecutor` (TCA26) | **320.0** | 318.9 | 320.8 | 3.12 M/s |

## Derived Metrics

| Delta | ns/op | Meaning |
|-------|------:|---------|
| C2 − C1 | **2,443** | Actor hop cost (single actor, one cross-executor hop) |
| C3 − C2 | **2,417** | Shape B witness overhead on top of raw actor hop (witness closure + internal actor indirection) |
| C3 − C4 | **4,878** | Savings from TCA26 shared-executor pattern |
| C4 ÷ C1 | **0.95×** | Shape B shared-path vs raw syscall (basically free) |
| C3 ÷ C1 | **15.4×** | Shape B default path vs raw syscall |

## Interpretation

**Headline**: The Shape B witness's fast path (shared-executor, TCA26) is essentially free — 0.95× raw syscall cost. The default path (cross-hop from cooperative pool) is 15× slower than raw and ~2× slower than a minimal actor-wrapped syscall.

### The three questions Item 6 asked

1. **"Is 3.9µs a structural ceiling?"** No. The shared-executor pattern reduces per-op overhead to **~320 ns** — below the raw syscall measurement itself. The 3.9µs number from `actor-hop-benchmark` was a no-op actor hop; with real syscall work, the shared path's overhead becomes negligible vs the syscall itself.

2. **"Does shared-executor adoption work in realistic stacked use?"** Yes. `SharedConsumer → IO.blocking(on: executor)` forwarding `unownedExecutor` gives Swift's runtime an executor-match on every `await`, and the measured zero-hop result confirms the elision fires.

3. **"Is Shape B's witness structure adding cost vs a plain actor?"** Yes, meaningfully. C3 − C2 = ~2,417 ns means the witness closure + internal-actor indirection roughly **doubles** the per-op cost on the unshared path compared to a plain actor with direct syscalls. This is the cost of `IO`'s closure-forwarding layer sitting on top of `IO.Blocking.Actor`.

### Why Config 4 is (slightly) faster than Config 1

Config 4 runs the hot loop on a dedicated OS thread (no task interruptions, better cache locality). Config 1 runs on the cooperative pool main task and may experience scheduler noise. The 17 ns gap is within measurement variance — treat them as equivalent.

### Where the 2,417 ns witness overhead comes from (hypothesis, not verified)

For every `try await io.read(...)`:
1. Generated forwarding method calls `try await _read(fd, buf)` — one async call through a `@Sendable` closure
2. Closure body calls `try await impl.read(...)` — one async call into the internal actor
3. Each async call may produce a separate continuation frame + heap allocation
4. The closure is `@Sendable`, which may disable some inlining that a direct async actor method would get

A hand-written `IO` without the `@Witness` closure layer might erase this overhead on the unshared path — the plain-actor result (C2) suggests ~2,400 ns as the floor.

However: this only matters for consumers who **don't** adopt the shared-executor pattern. TCA26 consumers pay zero witness overhead because the shared-executor optimization collapses everything.

## Decision Tree Verdict (from spec)

Per `HANDOFF-io-layered-implementation-review-response.md`:

> - If C4 ≤ 2× C1: commit Framing E. Shape B's fast path is competitive.
> - If C4 is 5-10× C1: write Framing B research note.
> - If C3 ≈ C2: overhead is Swift concurrency, not swift-io.
> - If C3 >> C2: Shape B witness adds measurable cost.

Measured: **C4 = 0.95× C1** (commit Framing E) and **C3 = 1.87× C2** (Shape B adds measurable cost, but only on the default path that consumers should avoid anyway).

**Verdict**: Framing E is safe to commit. The shared-executor pattern is not theoretical; it works as promised.

## Caveats

- **Pipe, not socket**: Darwin unix-domain pipe syscall latency is lower than TCP loopback. Real network I/O syscalls are typically 2-10× slower, which would **reduce the relative overhead** of the witness layer — the 2,417 ns overhead becomes a smaller fraction of a ~10 µs network syscall.
- **Single task**: Parallelism, contention, and the shared-executor pattern under load with multiple connections are not measured here. This benchmark confirms the per-op overhead floor under sustained single-task use.
- **No percentile distribution**: Mean ns/op from batch timing. The extremely tight trial ranges (C2/C3/C4 within 1-2%) suggest low variance. For p99 characterization, a follow-up benchmark recording per-op timestamps would be needed — but the timing overhead of `DispatchTime.now()` (~50 ns) dominates C4's 320 ns target, so per-op measurement is structurally noisy at this scale.
- **@Witness closure indirection vs hand-written**: The "witness overhead" number conflates (a) the structural cost of closure forwarding through `IO`'s `_read` closure and (b) the double-actor pattern (IO witness + IO.Blocking.Actor). A hand-written `IO` type with direct methods on the actor might close the gap — this is a separate measurement worth doing if witness overhead matters for a specific consumer.
- **Swift 6.3 specific**: Continuation allocation strategy and executor-match elision are compiler-dependent. Swift 6.4+ may change these numbers.

## Rerun

```bash
cd Experiments/io-stacked-actor-bench
swift build -c release
.build/release/bench
```

## Source

`Sources/bench/main.swift` — four configurations, three trials each, batch timing.
