# Executor Conformance Inventory

> Baseline: where `SerialExecutor` / `TaskExecutor` / `Executor` / `SchedulableExecutor`
> conformances live across the `swift-io` + `swift-file-system` dependency graphs.
> Purpose: triage for consolidation in `swift-executors`.
>
> Produced: 2026-04-15
> Packages scanned: 58
> Conformances found: 3

## Summary

| Layer | Package         | Count | Notes                                                       |
|-------|-----------------|------:|-------------------------------------------------------------|
| L3    | swift-executors |     1 | Baseline — target home for all executor conformances        |
| L3    | swift-io        |     2 | One in `IO Events` target, one in `IO Completions` target   |
| L3    | (all others)    |     0 | swift-file-system, swift-kernel, swift-async, swift-memory, swift-threads, swift-witnesses, swift-posix, swift-darwin, swift-linux, swift-windows, swift-clocks, swift-dependencies, swift-ascii, swift-environment, swift-paths, swift-strings, swift-systems |
| L2    | (all)           |     0 | swift-iso-9899, swift-iso-9945, swift-incits-4-1986, swift-rfc-4648, swift-darwin-standard, swift-linux-standard, swift-windows-standard, swift-x86-standard, swift-arm-standard |
| L1    | (all)           |     0 | 30 primitives packages — see Appendix                       |

**Total: 3 conformances across 2 packages.**

Breakdown by protocol:

- `SerialExecutor`: 3
- `TaskExecutor`: 3
- `Executor`: 0 explicit (implied by `SerialExecutor` and `TaskExecutor` refinement)
- `SchedulableExecutor`: 0

Every conformance site declares `SerialExecutor + TaskExecutor` together — there are no
`SerialExecutor`-only or `TaskExecutor`-only conformances in the dependency graph.

## Conformances by Layer

### Layer 3 (Foundations)

#### swift-executors

```
Type:          Kernel.Thread.Executor
File : line:   Sources/Executors/Kernel.Thread.Executor.swift:76
Declaration:   public final class Executor: SerialExecutor, TaskExecutor, @unchecked Sendable
Nested in:     extension Kernel.Thread { … }
Protocols:     SerialExecutor, TaskExecutor
@unchecked?:   no on executor protocols; yes on Sendable (internal synchronization —
               jobs enqueued under lock, executed serially on dedicated thread)
Conditional?:  no — no #if gates
Imports:       internal import Thread_Synchronization (no Executors product import —
               this IS the Executors product)
Purpose:       "A serial executor backed by a single dedicated OS thread."
               Run-loop owns one OS thread; Mode { .serial, .task } chooses which
               identity (asUnowned{Serial,Task}Executor) is reported on each
               runSynchronously call. Strict lifecycle: must shutdown() before
               deallocation; cannot shutdown from own thread; non-idempotent.
```

#### swift-io

```
Type:          IO.Event.Loop
File : line:   Sources/IO Events/IO.Event.Loop.swift:41
Declaration:   public final class Loop: SerialExecutor, TaskExecutor, @unchecked Sendable
Nested in:     extension IO.Event { … }
Protocols:     SerialExecutor, TaskExecutor
@unchecked?:   no on executor protocols; yes on Sendable (job queue lock-protected
               for cross-thread enqueue; remaining state thread-confined to
               executor's OS thread)
Conditional?:  no — no #if gates
Target:        "IO Events" — does NOT depend on Executors product
Imports:       public import Kernel; import Async, Thread_Synchronization,
               Ownership_Primitives, Buffer_Primitives
Purpose:       "An integrated I/O event loop: SerialExecutor + TaskExecutor + poll."
               Merges executor thread and poll thread into a single OS thread.
               Run loop: drain jobs → poll(deadline) → dispatch events → repeat.
               Owns ~Copyable event source; cross-thread entry limited to enqueue().
```

```
Type:          IO.Completion.Loop
File : line:   Sources/IO Completions/IO.Completion.Loop.swift:44
Declaration:   public final class Loop: SerialExecutor, TaskExecutor, @unchecked Sendable
Nested in:     extension IO.Completion { … }
Protocols:     SerialExecutor, TaskExecutor
@unchecked?:   no on executor protocols; yes on Sendable (job queue lock-protected
               for cross-thread enqueue; remaining state thread-confined to
               executor's OS thread)
Conditional?:  no — no #if gates
Target:        "IO Completions" — does NOT depend on Executors product
Imports:       public import Kernel; import Async, Thread_Synchronization,
               Ownership_Primitives, Dictionary_Primitives, Array_Dynamic_Primitives,
               Array_Primitives_Core, Dimension_Primitives
Purpose:       "An integrated proactor I/O loop: SerialExecutor + TaskExecutor +
               submit/poll." Merges executor thread and poll thread into one OS
               thread. Run loop: drain jobs → check cancellations → flush → poll
               → dispatch CQEs → repeat. Owns ~Copyable driver handle; cross-thread
               entry limited to enqueue() and wakeup.wake().
```

### Layer 2 (Standards)

No conformances. Verified across:

- `swift-iso/swift-iso-9899` (ISO 9899 — C language)
- `swift-iso/swift-iso-9945` (ISO 9945 — POSIX)
- `swift-incits/swift-incits-4-1986` (INCITS 4 — ASCII)
- `swift-ietf/swift-rfc-4648` (RFC 4648 — Base16/32/64)
- `swift-standards/swift-darwin-standard` (Darwin syscall surface)
- `swift-linux-foundation/swift-linux-standard` (Linux syscall surface)
- `swift-microsoft/swift-windows-standard` (Windows syscall surface)
- `swift-intel/swift-x86-standard` (x86 ISA)
- `swift-arm-ltd/swift-arm-standard` (ARM ISA)

### Layer 1 (Primitives)

No conformances. See Appendix for the full list.

## Appendix: Packages scanned with zero conformances

This list establishes that absence was verified, not overlooked.

### L3 Foundations (17)

- `swift-foundations/swift-file-system`
- `swift-foundations/swift-kernel`
- `swift-foundations/swift-async`
- `swift-foundations/swift-memory`
- `swift-foundations/swift-threads`
- `swift-foundations/swift-witnesses`
- `swift-foundations/swift-posix`
- `swift-foundations/swift-darwin`
- `swift-foundations/swift-linux`
- `swift-foundations/swift-windows`
- `swift-foundations/swift-clocks`
- `swift-foundations/swift-dependencies`
- `swift-foundations/swift-ascii`
- `swift-foundations/swift-environment`
- `swift-foundations/swift-paths`
- `swift-foundations/swift-strings`
- `swift-foundations/swift-systems`

### L2 Standards (9)

- `swift-iso/swift-iso-9899`
- `swift-iso/swift-iso-9945`
- `swift-incits/swift-incits-4-1986`
- `swift-ietf/swift-rfc-4648`
- `swift-standards/swift-darwin-standard`
- `swift-linux-foundation/swift-linux-standard`
- `swift-microsoft/swift-windows-standard`
- `swift-intel/swift-x86-standard`
- `swift-arm-ltd/swift-arm-standard`

### L1 Primitives (30)

- `swift-primitives/swift-clock-primitives`
- `swift-primitives/swift-buffer-primitives`
- `swift-primitives/swift-hash-primitives`
- `swift-primitives/swift-queue-primitives`
- `swift-primitives/swift-dimension-primitives`
- `swift-primitives/swift-ownership-primitives`
- `swift-primitives/swift-heap-primitives`
- `swift-primitives/swift-array-primitives`
- `swift-primitives/swift-dictionary-primitives`
- `swift-primitives/swift-memory-primitives`
- `swift-primitives/swift-algebra-primitives`
- `swift-primitives/swift-witness-primitives`
- `swift-primitives/swift-kernel-primitives`
- `swift-primitives/swift-system-primitives`
- `swift-primitives/swift-binary-primitives`
- `swift-primitives/swift-reference-primitives`
- `swift-primitives/swift-async-primitives`
- `swift-primitives/swift-standard-library-extensions`
- `swift-primitives/swift-source-primitives`
- `swift-primitives/swift-optic-primitives`
- `swift-primitives/swift-finite-primitives`
- `swift-primitives/swift-cache-primitives`
- `swift-primitives/swift-random-primitives`
- `swift-primitives/swift-string-primitives`
- `swift-primitives/swift-ascii-primitives`
- `swift-primitives/swift-base62-primitives`
- `swift-primitives/swift-ascii-serializer-primitives`
- `swift-primitives/swift-parser-primitives`
- `swift-primitives/swift-binary-parser-primitives`
- `swift-primitives/swift-serializer-primitives`

## Notes

### Structural shape

All 3 conformances share an identical structural signature:

```swift
public final class <Name>: SerialExecutor, TaskExecutor, @unchecked Sendable {
    private let sync: Kernel.Thread.Synchronization<1>
    private var jobs: <queue type>
    private var isRunning: Bool = true
    // …
    public func enqueue(_ job: consuming ExecutorJob) { … }
    public func asUnownedSerialExecutor() -> UnownedSerialExecutor { … }
}
```

All three are nested types declared via `extension <Outer> { public final class … }`.
All three combine a job queue (lock-protected for cross-thread `enqueue()`) with
thread-confined state (single OS thread runs the loop body).

### `@unchecked` placement

In all 3 cases, `@unchecked` is on `Sendable`, NOT on the executor protocols
themselves. The same docstring rationale appears verbatim across all three
("provides internal synchronization; job queue lock-protected; remaining state
thread-confined").

### Conditional gating

None of the 3 conformances are gated by `#if canImport(Darwin)`, `#if os(Linux)`,
or any other conditional compilation. They are unconditional on every supported
platform.

### Wrapping / delegation

None of the 3 conformances wrap or delegate to another executor. Each implements
`enqueue` directly against its own OS thread + job queue. They are siblings, not
a wrapper hierarchy.

### Cross-package import topology

- `swift-executors` declares `Kernel.Thread.Executor`. Its only use of executor
  protocols is implementing them on this one class.
- `swift-io/IO Blocking` target *imports* `Executors` and *holds* a
  `Kernel.Thread.Executor` (in `IO.Blocking.Actor`) but does not declare a
  conformance — it is a consumer.
- `swift-io/IO Events` and `swift-io/IO Completions` targets do **not** depend
  on `Executors`. Each declares its own loop class that conforms to
  `SerialExecutor + TaskExecutor` independently, using only `Kernel`,
  `Thread_Synchronization`, and primitives.

### Ambiguity / edge cases

None observed. No `extension … : SerialExecutor` retroactive conformances; no
`& SerialExecutor` composition patterns; no macro-generated conformances; no
`SchedulableExecutor` conformances anywhere in the dependency graph.

### Out of scope for this inventory

The following appear in the dependency graph but were not scanned (per spec —
`Sources/` and `Tests/` of path-resolved packages only):

- `swift-syntax` (URL dependency of `swift-witnesses` — external).
- `Experiments/` directories under `swift-io` (multiple `*Executor` conformances
  exist there in throwaway repro packages — not part of the production dependency
  closure).
- `Benchmarks/` directories under `swift-io` (nested benchmark packages —
  scanned, no conformances found).

### Verification

- Primary regex: `: (@unchecked )?(SerialExecutor|TaskExecutor|Executor|SchedulableExecutor)`
- Composition regex: `&\s+(SerialExecutor|TaskExecutor|SchedulableExecutor)\b`
- Retroactive regex: `^extension\s+\S+\s*:\s*[^,{]*(SerialExecutor|TaskExecutor|SchedulableExecutor)\b`
- Bare-name regex: `SerialExecutor|TaskExecutor|SchedulableExecutor` (used for
  cross-checking; surrounding context was inspected to filter out
  `UnownedSerialExecutor` returns, `any SerialExecutor` parameters, and
  docstring/MARK references).
- Each conformance site was opened and read to confirm the declaration line and
  extract docstring purpose.
