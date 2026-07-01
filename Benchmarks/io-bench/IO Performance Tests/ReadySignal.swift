//
//  ReadySignal.swift
//  swift-io / Benchmarks / io-bench
//
//  Async-bridging countdown latch for deterministic fixture setup.
//

import Kernel

/// Countdown latch that bridges from dedicated OS threads to async context.
///
/// Workers call `arrive()` from their dedicated threads. The async context
/// calls `await ready()` which suspends until all workers have arrived.
///
/// Unlike `Kernel.Thread.Barrier`, this latch does not block callers —
/// it resumes an async continuation, keeping the cooperative pool free.
///
/// ## Sending safety
///
/// The `CheckedContinuation` is stored internally and never exposed through
/// a `@Sendable @escaping` closure capture. Workers interact only via
/// `arrive()`, which is a plain method call on a `Sendable` reference type.
final class ReadySignal: @unchecked Sendable {
    private let mutex = Kernel.Thread.Mutex()
    private var count = 0
    private let target: Int
    private var continuation: CheckedContinuation<Void, Never>?

    init(target: Int) {
        self.target = target
    }

    /// Called from each worker thread to signal readiness.
    func arrive() {
        mutex.lock()
        count += 1
        if count >= target, let c = continuation {
            continuation = nil
            mutex.unlock()
            c.resume()
        } else {
            mutex.unlock()
        }
    }

    /// Suspends until `target` workers have called `arrive()`.
    ///
    /// If all workers have already arrived before this is called,
    /// returns immediately without suspending.
    func ready() async {
        await withCheckedContinuation { c in
            mutex.lock()
            if count >= target {
                mutex.unlock()
                c.resume()
            } else {
                continuation = c
                mutex.unlock()
            }
        }
    }
}
