//
//  Event.Actor.Lifecycle.Tests.swift
//  swift-io
//
//  F-001 regression (fable-448): after a fatal poll error halts the
//  reactor, the actor must leave `.running` and refuse new work —
//  `register` and `wait` throw `.left(.shutdown)` — instead of
//  accepting registrations against a dead poll loop and hanging
//  waiters forever.
//
//  §A9 note: these tests deliberately never complete a successful
//  `register` (which would drive the Kernel.Event.Driver registry
//  insert that SIGSEGVs on compiler(<6.4), catalog §A9 site 3), and
//  they deliberately LEAK the actor via `Sink` — `Polling.deinit` →
//  `Source.close()` → the driver's `__Dictionary.removeAll` hits the
//  same §A9 metadata SIGSEGV on compiler(<6.4). With both driver
//  entry points avoided, the suite runs cleanly on the 6.3.3
//  toolchain. Pre-fix, the state transition never happens and each
//  test fails via its time limit. Remove the `Sink` leak once the
//  fleet toolchain is ≥ 6.4.
//

import IO_Test_Support
@_spi(Syscall) import Kernel
import Testing

@testable import IO_Events

extension Event.Actor {
    @Suite
    struct `Edge Case` {}
}

extension Event.Actor.`Edge Case` {

    /// §A9 workaround: keeps test actors alive for the process lifetime
    /// so `Polling.deinit` (→ `Source.close()` → `__Dictionary.removeAll`
    /// metadata SIGSEGV on compiler(<6.4)) never runs. The halted poll
    /// threads have already exited; the leak is two dormant objects.
    private enum Sink {
        nonisolated(unsafe) static var actors: [Event.Actor] = []
        nonisolated(unsafe) static let lock = Kernel.Thread.Mutex()

        static func retain(_ actor: Event.Actor) {
            lock.withLock { actors.append(actor) }
        }
    }

    /// F-001: a fatal poll error (RetryDecision `.halt`) must transition
    /// the actor out of `.running`; a subsequent `register` must throw
    /// `.left(.shutdown)` rather than accept work against the dead poll
    /// loop. Pre-fix, `state` never leaves `.running` and the transition
    /// loop trips the time limit.
    @Test(.timeLimit(.minutes(1)))
    func `fatal poll error: actor leaves running and register fails fast`() async throws {
        let controller = Event.Fake.Controller()
        let actor = Event.Actor(source: Event.Fake.make(controller: controller))
        Sink.retain(actor)

        // .invalidDescriptor classifies as RetryDecision.halt.
        controller.failNextPoll(with: .invalidDescriptor)

        // The halt arm must run cleanup() on the reactor thread and set
        // state = .shuttingDown. Pre-fix this never happens.
        while await actor.state == .running {
            try await Task.sleep(for: .milliseconds(1))
        }

        // New work must be refused before touching the halted driver.
        let pipe = try Kernel.Pipe.pipe()
        await #expect(throws: Event.Failure.left(.shutdown)) {
            _ = try await actor.register(pipe.read)
        }
    }

    /// F-001: after the fatal-poll halt, `wait` must throw
    /// `.left(.shutdown)` immediately instead of enlisting a sender that
    /// no dispatch will ever drain (the pre-fix hang).
    @Test(.timeLimit(.minutes(1)))
    func `fatal poll error: wait fails fast instead of hanging`() async throws {
        let controller = Event.Fake.Controller()
        let actor = Event.Actor(source: Event.Fake.make(controller: controller))
        Sink.retain(actor)

        controller.failNextPoll(with: .invalidDescriptor)
        while await actor.state == .running {
            try await Task.sleep(for: .milliseconds(1))
        }

        // The watchdog converts a would-be hang into `.left(.cancelled)`,
        // which fails the `.shutdown` expectation instead of deadlocking.
        let waiter = Task { () async -> Event.Failure? in
            do throws(Event.Failure) {
                try await actor.wait(for: Event.ID(0), interest: .read)
                return nil
            } catch {
                return error
            }
        }
        let watchdog = Task {
            try? await Task.sleep(for: .seconds(2))
            waiter.cancel()
        }
        let failure = await waiter.value
        watchdog.cancel()
        #expect(failure == .left(.shutdown))
    }
}
