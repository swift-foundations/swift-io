# Σ_Completion — Effect Signature

> **CORRECTIVE BANNER (2026-04-20)**: This note overshot. It elaborates
> handler-internal operations (`submit_read`, `submit_write`,
> `submit_accept`, `submit_connect`, `submit_cancel`, `submit_poll`)
> into prose that reads like a public algebra spec. The **public Σ_IO
> is the four operations on `IO`**: `read`, `write`, `close`, `ready`
> (see `Sources/IO Core/IO.swift:133` and `Research/README.md`). The
> operations described below live inside `IO.Completion.Actor` and the
> `Kernel.Completion.Driver` witness; they are not consumer-facing. See
> `Sources/IO Completions/README.md` for the actual implementation
> shape.

<!--
---
version: 1.0.0
created: 2026-04-20
status: DRAFT
purpose: |
  Per-component signature note for the Completion (proactor)
  sub-theory of Σ_IO. Enumerates operations, types, and equational
  obligations on handlers.

basis: io-algebraic-effects-foundation.md §6.3, swift-io-thesis.md §3.3
---
-->

## 1. Position

Σ_Completion captures the **proactor** paradigm: the program submits
a fully-described IO operation (with buffer, offset, target) to the
kernel; the kernel performs the operation; the program receives the
result asynchronously when it completes. Buffer ownership transfers
to the kernel for the duration of the operation.

Σ_Completion is the second of two execution paradigms in Σ_IO; see
Σ_Event for the readiness/reactor counterpart. The two are
independent and may both be active in a single program (coproduct).

## 2. Operations

```
submit_read    : (FileDescriptor, Buffer, Offset) → Count
submit_write   : (FileDescriptor, Buffer, Offset) → Count
submit_accept  : FileDescriptor → FileDescriptor
submit_connect : (FileDescriptor, SocketAddress) → 1
submit_cancel  : CompletionToken → 1
submit_poll    : (FileDescriptor, ReadinessMask) → ReadinessSet
```

`submit_poll` is a hybrid bridge: it asks a Completion handler to
discharge a single Σ_Event-style readiness wait via the completion
mechanism (io_uring `IORING_OP_POLL_ADD`). It is in Σ_Completion (not
Σ_Event) because the result arrives via the completion queue.

Each `submit_*` operation is conceptually two algebraic operations
fused: enqueue + await-completion. The fused form is what consumers
observe; the handler internally manages the SQE/CQE split.

## 3. Types

| Symbol | Concrete Swift |
|--------|----------------|
| `FileDescriptor` | `Kernel.FileDescriptor` |
| `Buffer` | `Span<UInt8>` (caller-owned, lifetime-bound by `await`) |
| `Offset` | `Int64` (or sentinel for "current file position") |
| `Count` | `Int` (bytes transferred) |
| `SocketAddress` | `Kernel.SocketAddress` |
| `CompletionToken` | `IO.Completion.Token` (handler-issued, opaque) |
| `ReadinessMask` | `IO.Event.Mask` (shared with Σ_Event) |

Buffer ownership: from `submit_read` invocation until its
continuation resumes, the buffer is owned by the kernel. The Swift
surface enforces this via `await` (the suspending call holds the
buffer borrow alive).

## 4. Equational laws (E_Completion)

### 4.1 Single-completion
```
submit_X(args)   yields exactly one continuation invocation
```
Each submit corresponds to exactly one completion event. (Multishot
operations like multishot-receive are signature extensions, not part
of this base set; they violate single-completion.)

### 4.2 Cancel soundness
```
submit_X(args) >>= λt.
  submit_cancel(t)
  ≡
  submit_X(args) yields one of {success, cancelled};
  no double-completion, no leak
```
A cancel either races to interrupt the in-flight operation
(yielding `cancelled`) or arrives after the operation already
completed (yielding the original outcome). Either way, exactly one
result is observed.

### 4.3 Buffer-lifetime soundness
```
{submit_read(fd, buf, off)} owns(buf)   throughout
```
While the submit is in flight, no other party may read or write the
buffer. The handler's correctness depends on this; the Swift surface
enforces it via borrow scope tied to `await`.

### 4.4 Submission ordering undetermined
```
submit_A; submit_B   ≢   submit_B; submit_A
                       (in general; handler-defined)
```
Submissions in a single completion queue are *not* guaranteed
linearisable in submission order. Consumers requiring order must
chain via `await` (await A's continuation before submitting B).

### 4.5 Cancellation idempotence
```
submit_cancel(t); submit_cancel(t)   ≡   submit_cancel(t)
```
A second cancel on an already-cancelled or already-completed token
is a no-op (or a "no-such-token" error, handler-determined).

## 5. Handler obligations

A handler `H_Completion` for Σ_Completion must:

1. Maintain a submission queue (SQ) and completion queue (CQ).
   io_uring on Linux does this natively. On other platforms the
   handler emulates by reducing to Σ_Event (register POLLIN, do
   syscall, post result to CQ).
2. Discharge each `submit_*` by:
   a. Enqueueing the operation in the SQ.
   b. Awaiting its completion in the CQ.
   c. Resuming the caller with the result.
3. Discharge §4.1 — §4.5 of E_Completion.
4. Buffer ownership: ensure the buffer is not accessed by anything
   else while the operation is in flight.
5. **Single-poll-thread invariant**: at most one task drains the
   CQ at a time. This is a handler-level invariant, not a signature
   constraint, but it is load-bearing for E_Completion §4.1
   (single-completion).

Cancellation: `submit_cancel` is *the* cancellation mechanism. Task
cancellation maps to `submit_cancel` of the in-flight token, not to
silent abandonment.

## 6. Current implementation

| Element | Source |
|---------|--------|
| Handler witness | `IO.Completion.Driver` (capability struct) |
| Submission queue | `IO.Completion.Queue` |
| Operation types | `IO.Completion.{Read, Write, Accept, Connect}` |
| Poll bridge | Kernel.Completion.Submission.events + IORING_OP_POLL_ADD |
| Loop | `IO.Completion.Loop` (internal: SerialExecutor + TaskExecutor + poll) |
| Actor surface | `IO.Completions.Actor` (witness-shaped, multi-CQE cancel handshake) |
| Factory | `IO.completions(on:)` (Linux-only currently) |
| Error type | `IO.Completion.Error` |
| Platform handler | io_uring (Linux); Darwin/other emulate via Σ_Event |

See `completion-queue-ownership-redesign.md` for the
single-point-authority law-preservation argument; see
`io-uring-integration-architecture.md` for the io_uring binding.

## 7. Open work

1. **Multishot operations**: io_uring multishot accept / multishot
   recv yield multiple completions per submit. They violate §4.1
   (single-completion). They are useful and should be added — but
   as a signature extension `submit_multishot_*` with their own law
   set, not by relaxing §4.1.
2. **Linked / chained submits**: io_uring `IOSQE_IO_LINK` allows
   chaining submits with implicit ordering. Consider exposing as
   `submit_then : (Op, Op) → (Result, Result)` algebraic operation
   if a real consumer demand emerges.
3. **Buffer-group / fixed-buffer support**: io_uring's buffer ring
   feature lets the kernel pick a buffer from a pool. This changes
   the buffer-lifetime story (§4.3); needs explicit treatment if
   adopted.
4. **Cross-platform completion**: Windows IOCP (true completion
   model) maps cleanly here; macOS lacks a native completion
   mechanism (kqueue is readiness only). Document the emulation
   contract precisely so that consumers can reason about
   Darwin-vs-Linux performance.
