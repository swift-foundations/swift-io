//
//  IOFixture.swift
//  swift-io / Benchmarks / io-bench
//
//  Benchmark helpers for swift-io lane configuration.
//

import IO
import IO_Blocking_Threads
import IO_Test_Support
import Testing

// MARK: - Fixture Configurations

extension IOBenchmarkFixture {

    /// High-capacity lane matching NIO's unbounded queuing for fair comparison.
    static let highCapacity: IOBenchmarkFixture = {
        let fixture = IOBenchmarkFixture(options: .init(
            workers: 4,
            queueLimit: 4000,
            acceptanceWaitersLimit: 4000,
            backpressure: .wait
        ))
        Test.Teardown.register { await IOBenchmarkFixture.shared.shutdown() }
        Test.Teardown.register { await fixture.shutdown() }
        return fixture
    }()
}

