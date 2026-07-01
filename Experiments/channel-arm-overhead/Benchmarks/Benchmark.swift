// MARK: - Channel Arm Overhead: Async.Channel vs Raw Continuation
// Purpose: Measure round-trip notification latency to determine whether
//   Async.Channel can replace the hand-rolled Mutex+continuation IO arm machinery.
//
// Hypothesis: Async.Channel adds < 2x overhead vs current IO arm pattern,
//   making it viable as IO.Event.Channel arm infrastructure.
//
// Toolchain: Xcode 26.0 / Swift 6.2
// Platform: macOS 26.0 (arm64)
//
// Result: CONFIRMED (Unbounded) / REFUTED (Bounded)
// Revalidated: Swift 6.3.1 (2026-04-30) — STILL PRESENT
//   - Unbounded: 1.31 ms — 1.14x vs IO arm (within noise, viable)
//   - Bounded capacity=1: 5.70 ms — 4.96x vs IO arm (rejected)
//   - Bounded capacity=1000: 50.1–52.0 ms — lock contention dominates
//   - Raw continuation: 141 µs (floor)
//   - MutexQueue (IO arm): 1.15 ms (baseline)
// Date: 2026-03-27

import Synchronization
import Async_Channel_Primitives
import Testing

// MARK: - Root Suite

@Suite(.serialized) struct Benchmark {
    static let iterations = 1000
}

// MARK: - Variant 1: Raw CheckedContinuation

extension Benchmark {
    @Suite struct RawContinuation {}
}

extension Benchmark.RawContinuation {

    /// Baseline: pure continuation suspend/resume round-trip.
    /// One task suspends, another resumes. No queue, no coordination.
    @Test(.timed(iterations: 10, warmup: 2))
    func `1000 round-trips`() async {
        for _ in 0..<Benchmark.iterations {
            let _: Void = await withCheckedContinuation { continuation in
                continuation.resume()
            }
        }
    }
}

// MARK: - Variant 2: Mutex<[T]> + CheckedContinuation (IO arm pattern)

extension Benchmark {
    @Suite struct MutexQueue {}
}

extension Benchmark.MutexQueue {

    /// Simulates the IO arm pattern: enqueue entry to Mutex-protected array,
    /// dequeue on another task, resume continuation.
    ///
    /// This models: Channel.arm() enqueues Arm.Entry → Runtime dequeues → resumes.
    /// Excludes kqueue overhead to isolate machinery cost.
    @Test(.timed(iterations: 10, warmup: 2))
    func `1000 round-trips`() async {
        typealias Entry = CheckedContinuation<Void, Never>

        let queue = Mutex<[Entry]>([])

        // Consumer: polls and resumes continuations
        let consumer = Task.detached {
            var processed = 0
            while processed < Benchmark.iterations {
                let batch = queue.withLock { q in
                    let items = q
                    q.removeAll(keepingCapacity: true)
                    return items
                }
                for cont in batch {
                    cont.resume()
                    processed += 1
                }
                if batch.isEmpty {
                    await Task.yield()
                }
            }
        }

        // Producer: suspends via continuation, enqueues for consumer
        for _ in 0..<Benchmark.iterations {
            await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
                queue.withLock { q in
                    q.append(continuation)
                }
            }
        }

        await consumer.value
    }
}

// MARK: - Variant 3: Async.Channel.Bounded

extension Benchmark {
    @Suite struct BoundedChannel {}
}

extension Benchmark.BoundedChannel {

    /// Proposed replacement: Async.Channel.Bounded with capacity 1.
    /// Sender signals readiness, receiver awaits.
    @Test(.timed(iterations: 10, warmup: 2))
    func `1000 round-trips`() async throws {
        let channel = Async.Channel<Void>.Bounded(capacity: 1)
        let sender = channel.sender

        // Producer: sends readiness signals
        let producer = Task.detached {
            for _ in 0..<Benchmark.iterations {
                try await sender.send(())
            }
        }

        // Consumer: receives readiness signals
        for _ in 0..<Benchmark.iterations {
            _ = try await channel.receiver.receive()
        }

        _ = try await producer.value
    }

    /// Same but with larger element (simulating IO.Event payload).
    @Test(.timed(iterations: 10, warmup: 2))
    func `1000 round-trips with payload`() async throws {
        struct Event: Sendable {
            let id: UInt64
            let interest: UInt8
            let flags: UInt16
        }

        let channel = Async.Channel<Event>.Bounded(capacity: 1)
        let sender = channel.sender

        let event = Event(id: 42, interest: 1, flags: 0)

        let producer = Task.detached {
            for _ in 0..<Benchmark.iterations {
                try await sender.send(event)
            }
        }

        for _ in 0..<Benchmark.iterations {
            _ = try await channel.receiver.receive()
        }

        _ = try await producer.value
    }
}

// MARK: - Variant 3b: Async.Channel.Bounded (large capacity, no sender suspension)

extension Benchmark {
    @Suite struct BoundedChannelLargeCapacity {}
}

extension Benchmark.BoundedChannelLargeCapacity {

    /// Bounded with capacity = iterations. Sender never suspends (all fast-path).
    /// Isolates state machine overhead from suspension cost.
    @Test(.timed(iterations: 10, warmup: 2))
    func `1000 round-trips`() async throws {
        let channel = Async.Channel<Void>.Bounded(capacity: Benchmark.iterations)
        let sender = channel.sender

        let producer = Task.detached {
            for _ in 0..<Benchmark.iterations {
                try await sender.send(())
            }
        }

        for _ in 0..<Benchmark.iterations {
            _ = try await channel.receiver.receive()
        }

        _ = try await producer.value
    }
}

// MARK: - Variant 3c: Async.Channel.Bounded (large capacity, synchronous send)

extension Benchmark {
    @Suite struct BoundedChannelImmediate {}
}

extension Benchmark.BoundedChannelImmediate {

    /// Bounded with capacity = iterations, using send.immediate() (synchronous).
    /// Isolates Bounded state machine overhead from async calling convention.
    @Test(.timed(iterations: 10, warmup: 2))
    func `1000 round-trips`() async throws {
        let channel = Async.Channel<Void>.Bounded(capacity: Benchmark.iterations)
        let sender = channel.sender

        let producer = Task.detached {
            for _ in 0..<Benchmark.iterations {
                try sender.send.immediate(())
            }
        }

        for _ in 0..<Benchmark.iterations {
            _ = try await channel.receiver.receive()
        }

        _ = try await producer.value
    }
}

// MARK: - Variant 4: Async.Channel.Unbounded

extension Benchmark {
    @Suite struct UnboundedChannel {}
}

extension Benchmark.UnboundedChannel {

    /// Unbounded variant: send never suspends (synchronous enqueue).
    /// Lower overhead than Bounded since sender never needs to wait.
    @Test(.timed(iterations: 10, warmup: 2))
    func `1000 round-trips`() async throws {
        let channel = Async.Channel<Void>.Unbounded()
        let sender = channel.sender

        // Producer: sends are synchronous (never suspends)
        let producer = Task.detached {
            for _ in 0..<Benchmark.iterations {
                try sender.send(())
            }
        }

        for _ in 0..<Benchmark.iterations {
            _ = try await channel.receiver.receive()
        }

        _ = try await producer.value
    }
}
