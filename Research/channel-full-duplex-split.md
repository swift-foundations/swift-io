# Channel Full-Duplex Split

<!--
---
version: 1.0.0
last_updated: 2026-03-27
status: RECOMMENDATION
---
-->

## Context

IO.Event.Channel v1 serializes all operations. Read and write are both `mutating` on a `~Copyable` type, enforcing single-owner exclusive access. A pipelined write-then-read pattern (writing more data than the AF_UNIX socket buffer can hold before reading) deadlocks because:

1. Channel fills the send buffer → EAGAIN → arms for write readiness
2. Echo driver echoes data back → fills the receive buffer
3. Echo driver blocks on write (receive buffer full, Channel isn't reading)
4. Channel can't resume writing (send buffer full, echo driver stopped reading)

This is not a benchmark artefact. Any protocol that pipelines requests (HTTP/2, database query batching, SMTP) hits this on bounded socket buffers. NIO handles it transparently because the EventLoop interleaves reads and writes.

**Correctness test**: `IO.Event.Channel.Tests.swift` → `FullDuplex` → `pipelinedEcho` (currently `.disabled`). 500 × 64B over a socket pair deadlocks reliably.

**Performance impact**: The io-bench echo benchmark (27.53 ms vs NIO 11.73 ms, 2.3x) uses sequential write→read per round-trip because pipelining deadlocks. A fair comparison requires full-duplex.

## Question

How should IO.Event.Channel be upgraded to support concurrent read and write from independent tasks?

## Constraints

Seven hard constraints govern the design (from state analysis):

| ID | Constraint | Implication |
|----|-----------|-------------|
| C1 | Single kqueue/epoll registration per fd | Arm requests for read and write share one kernel entry |
| C2 | Single token (Registering/Armed typestate) | Two concurrent arm() calls violate the precondition |
| C3 | One-shot semantics (EV_DISPATCH / EPOLLONESHOT) | Kernel disables filter after one event delivery |
| C4 | Single fd close | Must close exactly once |
| C5 | Single deregister | Must deregister exactly once |
| C6 | Half-close independence | `.read` and `.write` bits are logically independent |
| C7 | Deinit ownership | One entity must own the cleanup path |

### Critical observation: C2 is weaker than it appears

The token is a compile-time safety mechanism, not a runtime capability. After the first arm(), Channel fabricates new `Token<Armed>(id: id)` locally — the selector/Runtime never validates tokens. The arm path enqueues an `Arm.Entry(id, interest, waiter, continuation)` to the MPSC queue; the Runtime processes it using the id and interest. Two concurrent arm entries for the same id with different interests are structurally valid at the queue level.

### Platform asymmetry on C1

- **kqueue**: `EVFILT_READ` and `EVFILT_WRITE` are separate kevents on the same fd. Concurrent read and write arms work naturally — they produce independent kernel events.
- **epoll**: `EPOLLIN | EPOLLOUT` are combined into one registration. Arms must be coordinated — the second arm modifies the first's interest mask. When either fires under EPOLLONESHOT, both are disabled; the still-pending interest must be re-armed.

## Analysis

### Option A: Two registrations per fd

Register the fd twice with the selector — once for read, once for write. Each half gets its own ID, token, and arm queue entry.

| Criterion | Assessment |
|-----------|-----------|
| kqueue | Works naturally (separate kevents per filter) |
| epoll | **Does not work** (one epoll_ctl per fd, shared interest mask) |
| io_uring | N/A (completion-based, separate SQEs per operation) |
| Complexity | Low per-platform, high cross-platform |
| Overhead | Zero (no coordination needed on kqueue) |

**Verdict**: Platform-asymmetric. Would require a completely different approach on Linux. Rejected.

### Option B: Shared coordinator

A shared `Sendable` storage object holds the immutable state (descriptor, id, selector, queues) and a coordination mechanism for the token and close lifecycle. Reader and Writer halves are both `~Copyable`.

```
Channel (consuming) → split() → (Channel.Reader, Channel.Writer)
                                      ↓               ↓
                                  ~Copyable         ~Copyable
                                  read()            write()
                                  shutdown.read()   shutdown.write()
                                      ↓               ↓
                                      └───── Shared ──┘
                                        descriptor, id
                                        selector, queues
                                        refcount, close()
```

**Token elimination**: The token typestate is unnecessary after split. The Runtime processes arm entries by id+interest; the token only prevents wrong-state usage at compile time. With two halves, each half's type encodes its capability (Reader can only arm for .read; Writer can only arm for .write). The typestate moves from runtime token to type-level enforcement.

**Close protocol**: Shared storage tracks a 2-bit "alive" mask. Each half's `consuming func close()` or deinit clears its bit. When both bits are cleared (last half standing), the storage triggers deregister + fd close.

**Arm coordination for epoll**: On epoll, the Runtime must combine pending interests. When processing an arm entry for .read while .write is already armed, it issues `epoll_ctl(EPOLLIN | EPOLLOUT | EPOLLONESHOT)`. When an event fires, it re-arms for any still-pending interest.

| Criterion | Assessment |
|-----------|-----------|
| kqueue | Works (separate kevents, no coordination needed in Runtime) |
| epoll | Works (Runtime combines interests in epoll_ctl) |
| io_uring | N/A |
| Complexity | Medium (shared storage + last-close protocol) |
| Overhead | One ARC increment/decrement per half creation; arm path unchanged (still MPSC queue, no actor hop) |
| Ecosystem alignment | Mirrors Async.Channel.Bounded pattern (shared Storage class, ~Copyable Receiver, Sender) |

**Verdict**: Recommended. Cross-platform, ecosystem-aligned, preserves the zero-actor-hop arm path.

### Option C: Borrow-based view (scoped split)

Channel stays as-is. A scoped API provides a read view and write view that borrow the Channel:

```swift
channel.withSplit { reader, writer in
    async let writes = pipelineWrites(writer)
    async let reads = drainReads(reader)
    _ = try await (writes, reads)
}
```

Views are `~Escapable`, valid only within the closure scope.

| Criterion | Assessment |
|-----------|-----------|
| Type safety | Excellent (lifetime-scoped, no ARC) |
| Complexity | Low |
| Overhead | Zero |
| Usability | Poor — scoped access prevents storing halves as properties or passing to other functions |
| Async compatibility | Questionable — `~Escapable` + async closures may hit compiler limitations |

**Verdict**: Too restrictive for real use. Protocols need to store the reader/writer for the connection lifetime, not just within a closure scope.

### Option D: Level-triggered mode

Drop one-shot semantics entirely. Register for `[.read, .write]` interest in level-triggered or edge-triggered mode. The kernel continuously reports readiness; no per-operation arm needed.

| Criterion | Assessment |
|-----------|-----------|
| kqueue | `EV_CLEAR` (edge-triggered) naturally supports this |
| epoll | `EPOLLET` (edge-triggered) naturally supports this |
| Complexity | High — fundamental architecture change, eliminates token system entirely |
| Overhead | Risk of busy-looping if events aren't properly drained |
| Backpressure | Lost — can't use arm frequency as a natural throttle |

**Verdict**: Valuable as a *complementary* optimization (reduces arm frequency for throughput), but too large a change to be the sole split mechanism. Could compound with Option B.

## Ecosystem Alignment

`Async.Channel` (Layer 1, `Async_Channel_Primitives`) establishes the split pattern:

| Async.Channel | IO.Event.Channel (proposed) |
|---------------|----------------------------|
| `~Copyable` channel | `~Copyable` channel |
| `Sender` (Copyable, shared) | `Writer` (~Copyable, unique) |
| `Receiver` (~Copyable, unique) | `Reader` (~Copyable, unique) |
| `Ends` (~Copyable bundle) | — (consuming `split()` returns tuple) |
| `Storage` (class, ARC lifetime) | Shared storage (class, ARC lifetime) |
| `take().ends()` consuming accessor | `split()` consuming method |

Difference: `Async.Channel.Sender` is Copyable (multiple producers). `IO.Event.Channel.Writer` should be `~Copyable` (single writer per socket direction — the kernel enforces this).

## Recommendation

**Option B (shared coordinator)** using `Async.Channel.Unbounded` as the notification mechanism.

### Empirical validation

Experiment `channel-arm-overhead` (2026-03-27) measured 1000 round-trip notification latencies:

| Mechanism | Median | vs IO arm |
|-----------|-------:|----------:|
| Raw continuation | 141 µs | 0.12x |
| Mutex+Array (current IO arm) | 1.15 ms | 1.0x |
| **Async.Channel.Unbounded** | **1.31 ms** | **1.14x** |
| Async.Channel.Bounded cap=1 | 5.70 ms | 4.96x |

Unbounded is at performance parity with the current hand-rolled arm machinery. Bounded is rejected (5x overhead from sender suspension + Phase enum + per-receive allocation).

Semantic fit is exact: Runtime sends events synchronously (`Unbounded.send` never suspends, 1 lock acquisition), Channel consumer awaits readiness (`receiver.receive()` suspends when empty).

### Design

1. **`consuming func split() -> (Channel.Reader, Channel.Writer)`** — consumes the Channel, returns two `~Copyable` halves sharing an ARC storage.

2. **Shared storage** (internal class, `@unchecked Sendable`):
   - All immutable fields from Channel (descriptor, id, selector, queues)
   - Two `Async.Channel<IO.Event>.Unbounded.Sender` (one for read events, one for write events)
   - 2-bit alive mask (atomic) for last-close protocol

3. **Reader**: `~Copyable, Sendable`. Owns `Async.Channel<IO.Event>.Unbounded.Receiver`. Has `read()`, `shutdown.read()`, `consuming func close()`. On EAGAIN: `try await readReceiver.receive()` replaces `arm(for: .read)`.

4. **Writer**: `~Copyable, Sendable`. Owns `Async.Channel<IO.Event>.Unbounded.Receiver`. Has `write()`, `shutdown.write()`, `consuming func close()`. On EAGAIN: `try await writeReceiver.receive()` replaces `arm(for: .write)`.

5. **Runtime changes**: When kqueue/epoll fires a read event for this id → `readSender.send(event)`. Write event → `writeSender.send(event)`. Replaces direct continuation resume.

6. **Close protocol**: Each half's close/deinit clears its alive bit. Last half triggers deregister + fd close. Closing a Sender signals the Receiver (channel close semantics).

7. **What this eliminates**: `IO.Event.Waiter`, `IO.Event.Arm.Entry`, `IO.Event.Arm.Queue`, the token typestate system, the manual `withCheckedContinuation` + `withTaskCancellationHandler` ceremony in `arm()`.

8. **Channel without split**: Unsplit Channel continues to work as-is for simple use cases. Split is opt-in.

### Phased implementation

| Phase | Work | Unlocks |
|-------|------|---------|
| 1 | Shared storage extraction + Unbounded channels per direction | Testable intermediate state |
| 2 | Replace arm() with receiver.receive(), Runtime sends via Sender | Simplified arm path, correctness parity |
| 3 | `split()` API + Reader/Writer types (kqueue) | Pipelined echo test passes on macOS |
| 4 | Runtime interest combining (epoll) | Linux full-duplex |
| 5 | Pipelined io-bench echo benchmark | Fair NIO comparison |

## References

- Correctness test: `Tests/IO Events Tests/IO.Event.Channel.Tests.swift` → `FullDuplex.pipelinedEcho`
- Benchmark: `Benchmarks/io-bench/IO Performance Tests/Channel.swift`
- Ecosystem precedent: `swift-primitives/swift-async-primitives/Sources/Async Channel Primitives/`
- Constraints analysis: `/tmp/channel-split-constraints.txt`
- Handoff: `HANDOFF.md` (performance parity with NIO)
