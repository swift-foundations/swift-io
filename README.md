# swift-io

![Development Status](https://img.shields.io/badge/status-active--development-blue.svg)

A high-performance async I/O executor for Swift. Isolates blocking syscalls from Swift's cooperative thread pool with dedicated worker threads, bounded queues, and deterministic shutdown semantics.

## Key Features

- **Dedicated thread pool** - Blocking I/O never starves Swift's cooperative executor
- **Context-based completion** - Eliminates dictionary lookups; jobs carry their own continuation
- **Transition-based signaling** - Signals only on empty→non-empty; drains batches per wake
- **Move-only resources** - Generic over `~Copyable` with type-safe slot transport
- **Typed throws end-to-end** - No `any Error` at the API surface
- **Swift 6 strict concurrency** - Full `Sendable` compliance, zero data races

## Design Philosophy

swift-io is designed for infrastructure code where correctness, determinism, and resource bounds matter more than absolute peak throughput. It intentionally trades unbounded queuing for predictable behavior under load.

**Non-goals:** swift-io does not aim to maximize throughput via unbounded queuing.

## Performance

Benchmarks comparing swift-io against SwiftNIO's `NIOThreadPool` (release mode, arm64, Apple M1). Medians reported; p95/p99 shown where tail latency differs significantly.

*Benchmarks simulate short blocking workloads (10µs each). Real I/O is syscall-dominated, reducing relative overhead differences. These benchmarks isolate executor behavior; they do not model end-to-end I/O latency.*

### Throughput

| Benchmark | swift-io | NIOThreadPool | Difference |
|-----------|----------|---------------|------------|
| Sequential (1000 × 10µs ops) | 4.51ms | 7.15ms | **37% faster** |
| Concurrent (1000 × 10µs ops) | 1.72ms | 1.43ms | NIO 17% faster |

### Overhead (per-operation, median)

| Benchmark | swift-io | NIOThreadPool | Difference |
|-----------|----------|---------------|------------|
| Thread dispatch | 4.00µs | 7.88µs | **49% faster** |
| Success path | 3.96µs | 7.83µs | **49% faster** |
| Failure path | 4.46µs | 10.79µs | **59% faster** |
| Queue admission | 4.13µs | 7.83µs | **47% faster** |

### Contention

| Scenario | swift-io | swift-io sharded | NIOThreadPool | Notes |
|----------|----------|------------------|---------------|-------|
| Moderate (10:1) | 216µs | 224µs | 182µs | NIO median wins; p95 swift-io 253µs vs NIO **671µs** |
| High (100:1) | 1.01ms | 568µs | 632µs | Sharded 10% faster than NIO |
| Extreme (1000:1) | 3.45ms | 2.54ms | 2.55ms | Sharded ties NIO |

### Design Wins

| Mechanism | Benefit | Measured |
|-----------|---------|----------|
| Context-based completion | Eliminates shared dictionary lookup | 83ns vs 1.50µs (**18×**) |
| Sharded lanes | Reduces lock contention under load | 40% faster than unsharded at 100:1 |

### Summary

swift-io prioritizes predictable latency, bounded resource usage, and deterministic shutdown over peak throughput. NIOThreadPool retains an advantage under highly concurrent workloads with unbounded queues; swift-io demonstrates lower per-operation overhead and more stable tail behavior under load.

### When to Use swift-io vs NIOThreadPool

- **Use swift-io** when you need bounded queues, deterministic shutdown, typed error preservation, or predictable tail latencies.
- **Use NIOThreadPool** when you want maximum concurrent throughput and accept unbounded queueing semantics.

## Why swift-io?

Conceptually, swift-io is an actor-managed pool of exclusive resources executed on bounded blocking lanes.

Swift's cooperative thread pool is designed for quick, non-blocking work. When you mix in blocking syscalls:

| Problem | Cooperative Pool | swift-io |
|---------|------------------|----------|
| **Blocking syscalls** | Starves cooperative threads | Dedicated threads isolate blocking work |
| **Waiter management** | Manual continuation handling | Bounded FIFO queues with backpressure |
| **Resource cleanup** | Manual, error-prone | Deterministic teardown strategies |
| **Cancellation** | Inconsistent semantics | Well-defined: before/after acceptance |
| **Move-only resources** | No native support | Generic over `~Copyable` with slot pattern |
| **Error handling** | Untyped throws | Typed throws with `IO.Lifecycle.Error<IO.Error<E>>` |

## Installation

```swift
dependencies: [
    .package(url: "https://github.com/coenttb/swift-io.git", from: "0.1.0")
]
```

```swift
.target(
    name: "YourTarget",
    dependencies: [
        .product(name: "IO", package: "swift-io"),
    ]
)
```

**Requirements:**
- Swift 6.2+ (swift-tools-version: 6.2)
- Apple platforms: macOS 26 / iOS 26 / tvOS 26 / watchOS 26
- Linux and Windows: See [Platform Support](#platform-support)

## Quick Start

### One-Shot Blocking Work

The simplest pattern—run blocking operations on dedicated threads:

```swift
import IO

let pool = IO.Executor.Pool<Void>()

let data = try await pool.run {
    try blockingSyscall()  // Runs on dedicated thread, not cooperative pool
}

await pool.shutdown()
```

### Managed Resources

For long-lived resources (file handles, connections), register them and use transactions:

```swift
import IO

let pool = IO.Executor.Pool<FileHandle>()

// Register → get ID
let id = try await pool.register {
    try FileHandle.open(path)
}

// Transaction → exclusive access
let data = try await pool.transaction(id) { handle in
    try handle.read()
}

// Destroy → cleanup
try pool.destroy(id)
await pool.shutdown()
```

### Domain Facade Pattern

For production use, wrap the pool in a domain-specific API (see [swift-file-system](https://github.com/coenttb/swift-file-system)):

```swift
public actor FileSystem {
    private let pool: IO.Executor.Pool<FileHandle>

    public init() { self.pool = IO.Executor.Pool() }

    public func read(
        at path: String
    ) async throws(IO.Lifecycle.Error<IO.Error<ReadError>>) -> Data {
        try await pool.run {
            try Data(contentsOfFile: path)
        }
    }

    public func shutdown() async { await pool.shutdown() }
}
```

### Error Handling

swift-io uses typed throws. Pool methods throw `IO.Lifecycle.Error<IO.Error<E>>`, which you can exhaustively pattern-match:

```swift
do {
    let value = try await pool.run {
        try myOperation()  // throws MyError
    }
} catch {
    switch error {
    case .shutdownInProgress:
        // Pool is shutting down
    case .cancellation:
        // Task was cancelled
    case .failure(let ioError):
        switch ioError {
        case .leaf(let myError):
            // myError is MyError (typed!)
        case .handle(let handleError):
            // e.g. .notFound, .scopeMismatch
        case .executor(let execError):
            // e.g. .waiterQueueFull
        case .lane(let laneError):
            // Lane infrastructure error
        }
    }
}
```

## Error Model

swift-io uses typed throws end-to-end. Public APIs do not throw `any Error`. Operation errors are preserved as `E` and lifted into `IO.Lifecycle.Error<IO.Error<E>>`.

The error hierarchy:

```
IO.Lifecycle.Error<E>
├── .shutdownInProgress    // Lifecycle: pool shutting down
├── .cancelled             // Lifecycle: task cancelled
└── .failure(E)            // Wraps operational errors
    └── IO.Error<Leaf>
        ├── .leaf(Leaf)    // Your operation's error type
        ├── .handle(...)   // Handle errors (.notFound, .scopeMismatch)
        ├── .executor(...) // Executor errors (.waiterQueueFull)
        └── .lane(...)     // Lane errors (.queue(.full), .overloaded)
```

## Architecture

```
┌─────────────────────────────────────────────┐
│                    IO                        │  ← Pool, Handle.ID, Error
├─────────────────────────────────────────────┤
│              IO Blocking                     │  ← Lane abstraction
├─────────────────────────────────────────────┤
│           IO Blocking Threads                │  ← Thread pool + signal optimization
├─────────────────────────────────────────────┤
│              IO Primitives                   │  ← Core types, platform abstraction
└─────────────────────────────────────────────┘
```

### Key Types

| Type | Purpose |
|------|---------|
| `IO.Executor.Pool<Resource>` | Actor-based resource pool with transaction access |
| `IO.Handle.ID` | Scoped identifier for registered resources |
| `IO.Blocking.Lane` | Execution backend (`.threads()` or `.sharded()`) |
| `IO.Lifecycle.Error<E>` | Lifecycle wrapper (shutdown, cancellation) |
| `IO.Error<E>` | Typed error preserving operation errors |

### Execution Model

```
Swift Task                    Lane (Thread Pool)
    │                              │
    ├─── run(operation) ──────────►│
    │    (suspends)                │
    │                              ├─── execute on worker thread
    │                              │
    │◄── resume with result ───────┤
    │    (context-based, no lookup)│
```

## Design Details

### Signal Optimization

Workers use transition-based signaling to minimize kernel overhead:

- **Sleepers tracking** - Only signal when workers are actually waiting
- **Empty→non-empty transitions** - Signal once per batch, not per job
- **Drain loop** - Process up to 16 jobs per wake cycle

This eliminates ~90% of spurious `pthread_cond_signal` calls compared to per-job signaling.

### Context-Based Completion

Jobs carry their completion context, eliminating shared dictionary state and lock-held hash operations:

```swift
// Traditional: O(1) amortized but with hash overhead + lock contention
completions[ticket] = result  // store under lock
let result = completions.removeValue(forKey: ticket)  // lookup under lock

// swift-io: Direct pointer, zero lookup, no shared dictionary
do { try job.context.complete(with: result) } catch {}  // 83ns, atomic CAS
```

### Guarantees

**What swift-io guarantees:**
- Exactly-once continuation resumption
- Bounded memory via capacity-limited queues
- Deterministic shutdown with in-flight completion
- Cancellation safety

**Fairness:**
- Queue order is FIFO
- Scheduling is best-effort under contention
- Completion order is not guaranteed (drain loops may reorder)

**What swift-io does NOT guarantee:**
- Syscall interruption after acceptance
- Strict FIFO completion under heavy contention
- Cross-process coordination

## Configuration

```swift
// Custom thread pool
let pool = IO.Executor.Pool<MyResource>(
    lane: .threads(.init(count: 4, queueLimit: 128)),
    handleWaitersLimit: 32
)

// Sharded lane for reduced contention
let pool = IO.Executor.Pool<MyResource>(
    lane: .sharded(count: 4)
)

// Custom teardown
let pool = IO.Executor.Pool<FileHandle>(
    teardown: .run { handle in
        try? handle.close()
    }
)
```

## Platform Support

CI covers macOS, Linux, and Windows on every push to main.

| Platform | CI | Status |
|----------|-----|--------|
| macOS | ✅ Swift 6.2, debug | Full support |
| Linux (Ubuntu) | ✅ Swift 6.2, release | Full support |
| Windows | ✅ Swift 6.2 | Full support |
| iOS/tvOS/watchOS | — | Supported (same codebase as macOS) |

## Related Packages

- [swift-file-system](https://github.com/coenttb/swift-file-system) - File system operations built on swift-io
- [swift-time-standard](https://github.com/swift-standards/swift-time-standard) - Time types for deadlines

## License

Apache 2.0 - See [LICENSE](LICENSE) for details.
