# Actor hop benchmark results

**Hardware**: Apple M-series, macOS 26.
**Swift**: 6.3 (Xcode 6.3.0.123.5).
**Build**: `swift build -c release`.
**Iterations**: 500,000 per scenario, warmup 10,000.
**Trials**: 3 runs, stable to ~2%.

## Results

| Scenario | ns/op | Description |
|----------|-------|-------------|
| cross-hop | **~3900** | Option F worst case. `await io.noop()` from cooperative pool → IO on dedicated `Kernel.Thread.Executor`. Each call enqueues a job, thread wakes, runs, enqueues continuation, caller wakes. |
| shared-executor | **~11** | Option F with TCA26 pattern. Caller is an actor whose `unownedExecutor` matches IO's executor. Runtime's match-check elides the hop at `await`. |
| task-preference(.task) | ~1 | Option A amortized. One `Task(executorPreference:)` setup, N sync closure calls inside. Per-call cost after setup. |
| task-preference(.serial) | ~1 | Same shape, `.serial`-mode executor. |
| same-actor-method | ~0 | Isolated method calling another isolated method on same actor. Pure Swift call. |
| actor.run body | ~1 | Option B fast-path. One hop via `Actor.run`, N sync calls inside with isolated Self. |

## Interpretation

### Per-op cost for a single operation

For ONE I/O call (N=1):

- **Option A** (`Task(executorPreference:)` + sync closure): ~5 µs total (Task setup dominates).
- **Option B** (Actor.run body): ~4 µs total (one hop into actor).
- **Option F cross-hop**: ~4 µs total (one hop into actor).
- **Option F shared-executor**: ~11 ns.

For N=1 the three body-containing options are within ~20% of each other. Shared-executor Option F is ~350× cheaper.

### Per-op cost amortized (N I/O calls per scope)

| N | Option A | Option B | F cross-hop | F shared |
|---|----------|----------|-------------|----------|
| 1 | ~5 µs | ~4 µs | ~4 µs | ~11 ns |
| 10 | ~0.5 µs | ~0.4 µs | ~4 µs | ~11 ns |
| 100 | ~50 ns | ~40 ns | ~4 µs | ~11 ns |
| 1000 | ~6 ns | ~5 ns | ~4 µs | ~11 ns |

Options A and B amortize the one-time setup across the body; Option F cross-hop pays per call; Option F shared is flat because there's no hop to amortize.

### When does the 4 µs per-op cost matter?

Compare to the I/O operation itself:

- **Disk read/write**: 10–100+ µs per syscall. Hop is 4–40% overhead — measurable but not dominant.
- **Pipe / socket (loopback)**: 1–5 µs. Hop dominates.
- **io_uring submit+complete (Phase 2)**: 100 ns–1 µs. Hop is 4–40× overhead — dominant.

For blocking I/O (Phase 1), 4 µs per op is acceptable for typical request-handling code. For completion-driven I/O (Phase 2), the shared-executor pattern becomes essential.

### Recommendation

Default consumer code should just write `try await io.read(...)`. In the common case (a handful of I/O calls per request, each gated by 10+ µs syscalls), the 4 µs hop is in the noise.

When profiling shows hop cost dominating:
1. Co-locate the consumer actor with IO's executor (TCA26 pattern). The `(on:)` factory overload enables this. 350× speedup at zero API change.
2. Consider batch APIs on IO for hot loops (e.g. `io.drain(from: fd)`) — future work.

## Caveats

- The benchmark measures a trivial `noop()` — zero work per call. Real I/O adds the syscall cost on top; actor hop cost is constant, so relative overhead drops as syscall cost rises.
- Single executor, one actor. Contention under concurrent access not measured.
- Enqueue implementation is `Kernel.Thread.Executor` — mutex + condvar + cross-thread wakeup. Alternative executors (dispatch queue, cooperative executor) would have different constants. The ratio between cross-hop and shared-executor should hold regardless.
- Per-op costs are averages; tail latencies may be worse under load. Not measured.

## Rerun

```
cd Experiments/actor-hop-benchmark
swift build -c release
.build/release/bench
```

## Source

`Sources/bench/main.swift` — 500k iterations per scenario, `@inline(never)` on hot paths, mutable counters to defeat constant folding, `blackHole` sink to defeat dead-code elimination.
