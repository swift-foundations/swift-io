//
//  WorkSimulator.swift
//  swift-io / Benchmarks
//
//  Identical work simulation for fair cross-framework comparison.
//  This file MUST be byte-identical in io-bench and nio-bench.
//

import Testing

/// Simulates CPU-bound blocking work without actual I/O.
///
/// Uses `ContinuousClock` (Swift stdlib) for portable, monotonic timing.
/// Clock is checked every 64 iterations to bound measurement overhead.
enum WorkSimulator {

    @inline(never)
    static func simulateWork(duration: Duration) {
        let deadline = ContinuousClock.now.advanced(by: duration)
        var sum = 0
        var counter = 0
        while true {
            sum &+= counter
            counter += 1
            if counter & 63 == 0 {
                if ContinuousClock.now >= deadline { break }
            }
        }
        withExtendedLifetime(sum) {}
    }
}

// MARK: - Tests

extension WorkSimulator {

    @Suite
    struct Test {
        @Suite struct Unit {}
        @Suite struct EdgeCase {}
        @Suite struct Integration {}
        @Suite(.serialized) struct Performance {}
    }
}

extension WorkSimulator.Test.Unit {

    @Test
    func `10µs work completes within reasonable bounds`() {
        let start = ContinuousClock.now
        WorkSimulator.simulateWork(duration: .microseconds(10))
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .microseconds(10))
        #expect(elapsed < .milliseconds(10))
    }

    @Test
    func `1ms work completes within reasonable bounds`() {
        let start = ContinuousClock.now
        WorkSimulator.simulateWork(duration: .milliseconds(1))
        let elapsed = ContinuousClock.now - start
        #expect(elapsed >= .milliseconds(1))
        #expect(elapsed < .milliseconds(50))
    }
}
