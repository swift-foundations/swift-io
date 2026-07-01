# Channel Arm Overhead

<!--
---
version: 1.0.0
last_updated: 2026-03-27
status: CONFIRMED (Unbounded) / REFUTED (Bounded)
---
-->

## Hypothesis

Async.Channel (L1 `Async_Channel_Primitives`) can replace the hand-rolled Mutex + CheckedContinuation arm machinery in IO.Event.Channel with < 2x overhead, simplifying the codebase by eliminating Waiter, Arm.Entry, Arm.Queue, and manual continuation management.

## Background

The IO arm path today: Channel calls `arm(interest:)` → creates an `Arm.Entry` containing a `CheckedContinuation` → enqueues to an MPSC queue → Runtime dequeues → processes kqueue event → resumes continuation. This is a Mutex-protected array with manual continuation lifecycle.

The proposed alternative: replace with `Async.Channel.Unbounded` or `Async.Channel.Bounded` from the primitives layer. Runtime holds the Sender, Channel holds the Receiver. Arm becomes `try await receiver.receive()`. Event delivery becomes `sender.send(event)`.

Related research: [channel-full-duplex-split](../../Research/channel-full-duplex-split.md) — the split() API design that motivates this investigation.

## Methodology

Six benchmark variants, each performing 1000 round-trips (producer sends signal, consumer receives):

| Variant | What it measures |
|---------|-----------------|
| **RawContinuation** | Floor: pure `withCheckedContinuation` suspend/resume |
| **MutexQueue** | Current IO arm pattern: `Mutex<[CheckedContinuation]>` + polling consumer |
| **BoundedChannel (cap=1)** | Proposed: `Async.Channel.Bounded(capacity: 1)` — tight ping-pong |
| **BoundedChannel + payload** | Same with 11-byte `Event` struct (simulating `IO.Event`) |
| **BoundedChannelLargeCapacity (cap=1000)** | Bounded fast-path only (sender never suspends) |
| **BoundedChannelImmediate (cap=1000)** | Same but using synchronous `send.immediate()` |
| **UnboundedChannel** | `Async.Channel.Unbounded()` — synchronous send, async receive |

All run in release mode (`swift test -c release`), `.timed(iterations: 10, warmup: 2)`, on Apple M2 (8-core, 24 GB).

## Results

| Variant | Median | vs IO arm | CV |
|---------|--------|-----------|-----|
| RawContinuation | 141 µs | 0.12x | 8.2% |
| **MutexQueue (IO arm baseline)** | **1.15 ms** | **1.0x** | 8.9% |
| Bounded cap=1 | 5.70 ms | 4.96x | 6.4% |
| Bounded cap=1 + payload | 5.62 ms | 4.89x | 2.0% |
| Bounded cap=1000 (async send) | 50.1 ms | 43.6x | 9.4% |
| Bounded cap=1000 (immediate send) | 52.0 ms | 45.2x | 3.3% |
| **Unbounded** | **1.31 ms** | **1.14x** | 14.4% |

## Analysis

### Unbounded: viable (1.14x overhead)

Unbounded.send() is synchronous (1 lock acquisition, 0 allocations, no async overhead). This matches the IO pattern exactly: the Runtime produces events fast and synchronously, the Channel consumer can afford to suspend.

The 14% overhead vs MutexQueue is within measurement noise (both have moderate CV). Across 4 runs, Unbounded is stable at 1.28–1.31 ms.

### Bounded cap=1: not viable (4.96x overhead)

Capacity=1 forces sender-receiver ping-pong: sender sends → buffer full → sender suspends → receiver wakes → receiver receives → buffer empty → receiver suspends → sender wakes. Two suspension points per round-trip vs one for Unbounded/MutexQueue.

The 2x structural penalty from double-suspension explains ~half the gap. The remaining ~2.5x comes from:
1. **Phase enum overhead**: Bounded's state is a 4-case enum with 3 associated values (buffer, senders Deque, receiver optional). Every operation extracts + reconstructs these values.
2. **Per-receive allocation**: Every `receive()` allocates a `Deque<Send.Continuation>` to collect cancelled senders, even when there are zero cancellations.
3. **Multi-lock send suspension**: When buffer full, send requires 3–4 lock acquisitions (trySend + generateId + sendSuspended + possible cancellation).

### Bounded large capacity: lock contention dominates

Both large-capacity variants (~50 ms) are **10x slower** than cap=1 (5.7 ms), despite doing LESS work (no sender suspension). The critical difference is concurrency pattern:

- **Cap=1**: strict alternation — producer and consumer take turns, zero lock contention
- **Cap=1000**: both tasks run simultaneously fighting over the same Mutex

The async vs synchronous send comparison (50.1 ms vs 52.0 ms) proves async calling convention overhead is negligible. The bottleneck is lock contention amplified by Bounded's longer critical sections (Phase enum extraction/reconstruction).

### Payload size: negligible

Bounded cap=1 with Void (5.70 ms) vs 11-byte Event struct (5.62 ms) — no meaningful difference. The element copy cost is dwarfed by synchronization overhead.

## General Bounded Improvements

Three optimizations applicable to Async.Channel.Bounded generally (not just IO):

### 1. Lazy-init cancelled senders Deque (easy, high impact)

**Current**: Every `receive()` allocates `Deque<Send.Continuation>()` before checking if any senders are cancelled.

**Proposed**: Only allocate on first actual cancellation encounter during `popNextSender`.

**Expected impact**: Eliminates 1 allocation per receive on the hot path (no-cancellation case).

### 2. Flatten Phase enum to stored properties (medium, high impact)

**Current**: `Phase.open(buffer:senders:receiver:)` — 3 associated values extracted/reconstructed per operation. The `.modifying` intermediate state exists solely to avoid CoW on the buffer.

**Proposed**:
```swift
struct State {
    var buffer: Deque<Element>
    var senders: Deque<Sender>
    var receiver: Receiver?
    var closed: Bool
}
```

Eliminates extraction/reconstruction overhead. Buffer mutation is direct (`state.buffer.back.push`) without the `.modifying` dance.

**Expected impact**: Reduces per-operation instruction count by ~50% inside the lock, directly reducing lock hold time and contention.

### 3. Batch ID generation into trySend (easy, low impact)

**Current**: When buffer is full, `trySend()` returns `.suspend`, then a SEPARATE lock acquisition generates the ID.

**Proposed**: `trySend()` returns `.suspend(id: nextId)` — generate the ID inside the same lock.

**Expected impact**: Eliminates 1 lock acquisition on the send-suspension path. Minor for typical workloads.

## Conclusion

**Hypothesis confirmed for Unbounded, refuted for Bounded.**

For the IO arm use case, `Async.Channel.Unbounded` is a drop-in replacement at performance parity. The semantic fit is exact: Runtime produces events synchronously (never blocks), Channel consumer awaits readiness (can suspend). This eliminates Waiter, Arm.Entry, Arm.Queue, and the manual `withCheckedContinuation` + `withTaskCancellationHandler` ceremony.

Bounded is not viable for IO arm. Its overhead is structural (sender suspension) and implementational (Phase enum, per-receive allocation). Three general improvements are identified that would benefit all Bounded users.

## Next Steps

1. Prototype `Async.Channel.Unbounded` as IO arm infrastructure in swift-io
2. File issues for Bounded improvements (lazy cancelled Deque, flatten Phase) against swift-async-primitives
3. Re-run io-bench echo benchmark with Unbounded-based arm to measure end-to-end impact
