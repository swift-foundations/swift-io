# proactor-buffer-ownership — results

<!--
---
version: 1.0.0
created: 2026-04-14
status: Q2 gate resolved — unified _read witness signature confirmed safe
related:
  - swift-io/Research/io-phase-2-plan.md §2 Q2
  - swift-io/Research/io-architecture.md v1.2 "Buffer ownership" open item
---
-->

## Question

Does the unified `_read(borrowing Kernel.Descriptor, Memory.Buffer.Mutable)
async throws(IO.Error) -> Int` signature survive the move to io_uring
completions, where the kernel retains the buffer pointer from SQE
submission through CQE consumption?

Per `swift-io/Research/io-phase-2-plan.md` §2 Q2: the answer gates the
witness signature for Phase 2C. Pass → keep unified `_read`. Fail →
split proactor into `_readRegistered`.

## Setup

- `swiftlang/swift:nightly-main` (Swift 6.4-dev) on Docker — aarch64 Linux
- `liburing` linked from `liburing-dev` (Ubuntu Noble package)
- io_uring ring with 32 SQE entries
- One dedicated poll thread calling `io_uring_wait_cqe`; per-SQE
  `CheckedContinuation` resumed from the poll thread via a
  `user_data → continuation` map
- `docker run --rm --privileged` (io_uring_setup syscall requires it
  inside containers)

## Tests

### A — heap-backed buffer across `try await`

1. Create pipe; get read fd + write fd.
2. Allocate a 16-byte heap buffer
   (`UnsafeMutableRawBufferPointer.allocate`), zero-init.
3. Spawn a producer `Task.detached`: sleep 5 ms, write 4 bytes
   (`DE AD BE EF`) to the pipe's write end.
4. From main: submit a `IORING_OP_READ` SQE with the heap buffer
   pointer + the pipe's read fd. Suspend on a `CheckedContinuation`.
5. Poll thread observes the CQE after the producer's write lands.
   Extracts the result, resumes the continuation.
6. Assert: buffer holds the 4 bytes.

### B — cancellation mid-flight

1. Create pipe; **no producer** — the read will block indefinitely.
2. Allocate a 16-byte heap buffer, fill with sentinel `0xAA`.
3. Submit `IORING_OP_READ` SQE + suspend on a `CheckedContinuation`.
4. `Task.sleep(10 ms)` to let the SQE reach the kernel.
5. Submit `IORING_OP_ASYNC_CANCEL` for the first SQE's `user_data`.
6. Poll thread observes the cancel CQE (dropped — no matching
   continuation) AND the original SQE's CQE (`res == -ECANCELED`).
7. Assert: `res < 0` AND buffer bytes all remain `0xAA`.

## Results

```
=== proactor-buffer-ownership experiment ===

testA PASS: buffer = [DE AD BE EF] (4 bytes delivered across suspension)
testB PASS: cancelled SQE returned res=-125 (expected -ECANCELED = -125); sentinel intact
```

Both tests pass on the first run. No flakes observed across repeated
runs (`./run.sh` 10x, all green).

## Findings

### 1. Heap-backed buffer survives suspension

A buffer whose pointer is captured by `io_uring_prep_read` at SQE
submission time is stable across a Swift task suspension. The mechanism
is independent of io_uring:

- Swift's task frame is heap-allocated; local variables inside an async
  function live in that frame regardless of suspension state.
- An `UnsafeMutableRawBufferPointer.allocate(...)` return is a pointer
  to heap memory; its address is stable for the lifetime of the
  allocation.
- Array-backed storage (`var buffer = [UInt8](...)`) is heap-allocated
  for non-trivially-sized values; same stability.

The kernel holds the raw pointer (not the Swift value). Consumers
using normal Swift buffer patterns get address stability for free.
**No special handling needed on the caller side.**

### 2. Cancellation is a correctness requirement on the Completions factory

`IORING_OP_ASYNC_CANCEL` with the original SQE's `user_data`
successfully terminates the in-flight read. The buffer is not
touched; the cancel completes promptly; the original SQE's CQE
arrives with `res = -ECANCELED`.

This proves the mechanic, but it also reveals a *correctness
requirement* for the production Completions factory: when a Swift
`Task` is cancelled mid-`_read`, the factory MUST

1. submit `IORING_OP_ASYNC_CANCEL` for the outstanding `user_data`;
2. keep the buffer alive in the task frame until the original SQE's
   CQE arrives (with `-ECANCELED`);
3. only then resume the continuation (throwing `IO.Error.cancelled`)
   and allow the caller's frame to unwind.

`withTaskCancellationHandler` is the Swift pattern:

```swift
try await withTaskCancellationHandler {
    await withCheckedContinuation { /* submit + suspend */ }
} onCancel: {
    submitCancel(userData)
    // task frame stays alive until the original CQE fires; the
    // `onCancel` closure runs nonisolated, so the submission is
    // non-blocking.
}
```

If the factory skips this and simply resumes the continuation on
task-cancellation signal (without cancelling the SQE), the kernel
eventually writes to the buffer whose owning frame has unwound —
potential UAF depending on heap reuse timing.

**The requirement lives in the Completions factory implementation,
not in the witness signature.**

### 3. `~Escapable` already prevents the stack-based hazard

The architecture doc v1.2's concern about "stack-allocated
`MutableSpan` views" is compile-time prevented by `~Escapable`:

```swift
var local = [UInt8](repeating: 0, count: 16)
local.withUnsafeMutableBytes { buf in
    await io.read(from: fd, into: Memory.Buffer.Mutable(buf)) // ← OK
}
// After the closure, `buf` is dead — but the closure is non-escaping,
// so anything awaiting inside keeps the array alive.
```

Any attempt to hold a `MutableSpan<UInt8>` from a local value across
an `await` that could cause the frame to drop would fail compilation
per the `~Escapable` lifetime rules. The witness signature accepts
`Memory.Buffer.Mutable` (an `UnsafeMutableRawBufferPointer` wrapper),
which is `Escapable` but has stable address semantics.

## Conclusion

**Q2 PASS — keep the unified `_read` signature.**

The witness contract is:

> `Memory.Buffer.Mutable` / `Memory.Buffer` parameters to `_read`,
> `_write`, and `_ready` MUST refer to storage with a stable address
> for the duration of the enclosing `try await` expression. Heap-backed
> storage (Array, `UnsafeMutableRawBufferPointer.allocate`,
> `Buffer.Aligned`, etc.) satisfies this trivially. Stack-allocated
> `MutableSpan` views are prevented from crossing `await` boundaries
> by Swift's `~Escapable` lifetime rules.
>
> Under the events and completions strategies, the factory internally
> ensures the buffer outlives any in-flight SQE. For completions, this
> means cancellation paths MUST use `withTaskCancellationHandler` to
> submit `IORING_OP_ASYNC_CANCEL` and wait for the original SQE's CQE
> before the task frame unwinds.

Phase 2C proceeds with:

- Unified `_read` / `_write` / `_close` / `_ready` signatures
  across all three strategies.
- No `_readRegistered` split.
- Completions factory implementation includes
  `withTaskCancellationHandler` for the in-flight-SQE-then-cancel
  path — documented in `IO.swift` doc comments and a regression
  test in the Completions factory tests.

## Reproduce

```bash
cd swift-io/Experiments/proactor-buffer-ownership
./run.sh
```

Requires Docker + Linux support (io_uring is Linux-only). Uses
`swiftlang/swift:nightly-main` + `liburing-dev`. `--privileged` is
required for io_uring_setup inside the container.

## Experiment layout

```
Experiments/proactor-buffer-ownership/
├── Package.swift                      Swift 5 language mode (experiment
│                                      avoids strict-concurrency friction
│                                      for shared UnsafeMutableRawBufferPointer
│                                      across Task.detached closures)
├── Dockerfile                         swiftlang/swift:nightly-main + liburing-dev
├── run.sh                             build + run via Docker
├── RESULTS.md                         this document
└── Sources/
    ├── CUring/
    │   ├── CUring.c                   placeholder TU
    │   └── include/CUring.h           static-inline liburing wrappers
    └── experiment/
        └── main.swift                 the 2 tests
```

Total: ~300 LOC of Swift + C (slightly above the plan's 100–200 LOC
target due to the PollThread's continuation-map bookkeeping, which
a production Completions factory would replace with per-operation
state in IO.Completions.Actor).
