//
//  Event.Fake.swift
//  swift-io
//
//  Deterministic fake event source for testing non-blocking I/O invariants.
//

import IO_Test_Support
@_spi(Syscall) @_spi(Internal) import Kernel
import Synchronization

@_spi(Syscall) @testable import IO_Events

// MARK: - Fake Source

extension Event {
    /// Deterministic fake event source for testing.
    enum Fake {}
}

extension Event.Fake {
    /// Creates a fake event source controlled by the given controller.
    ///
    /// The returned `Kernel.Event.Source` uses the L1 Driver (with ID
    /// generation, registry, and staleness suppression) backed by fake
    /// closures that delegate to the Controller.
    static func make(controller: Controller) -> Kernel.Event.Source {
        let fakeWakeup = Kernel.Wakeup.Channel {
            controller.state.withLock { $0.wakeupPending = true }
        }

        let driver = Kernel.Event.Driver(
            add: { (fd: borrowing Kernel.Descriptor, id: Kernel.Event.ID, interest: Kernel.Event.Interest) throws(Kernel.Event.Driver.Error) in
                try controller.add(fd: fd, id: id, interest: interest)
            },
            modify: { (fd: borrowing Kernel.Descriptor, id: Kernel.Event.ID, old: Kernel.Event.Interest, new: Kernel.Event.Interest) throws(Kernel.Event.Driver.Error) in
                try controller.modify(fd: fd, id: id, old: old, new: new)
            },
            remove: { (fd: borrowing Kernel.Descriptor, id: Kernel.Event.ID, _: Kernel.Event.Interest) throws(Kernel.Event.Driver.Error) in
                try controller.remove(fd: fd, id: id)
            },
            arm: { (fd: borrowing Kernel.Descriptor, id: Kernel.Event.ID, interest: Kernel.Event.Interest) throws(Kernel.Event.Driver.Error) in
                try controller.arm(fd: fd, id: id, interest: interest)
            },
            poll: { (_: Clock.Continuous.Deadline?, output: inout [Kernel.Event]) throws(Kernel.Event.Driver.Error) -> Int in
                try controller.poll(into: &output)
            },
            close: {
                controller.close()
            }
        )

        return Kernel.Event.Source(driver: driver, wakeup: fakeWakeup)
    }
}

// MARK: - Controller

extension Event.Fake {
    /// Test controller for the fake event source.
    ///
    /// Tracks backend operations called by the L1 Driver. The Driver manages
    /// IDs and registry internally — the Controller just records what the
    /// backend receives and provides events for polling.
    final class Controller: @unchecked Sendable {
        let state: Mutex<State>

        init() {
            self.state = Mutex(State())
        }
    }
}

extension Event.Fake.Controller {
    struct State {
        /// Backend-tracked registrations (mirrors what add/remove receive).
        var registrations: [Kernel.Event.ID: Registration] = [:]
        /// Events to deliver on next poll.
        var pendingEvents: [Kernel.Event] = []
        /// Wakeup signal pending.
        var wakeupPending: Bool = false
        /// Simulate shutdown (reject operations).
        var isShutdown: Bool = false
        /// Whether close() was called.
        var isClosed: Bool = false
        /// Error the next poll throws (one-shot), simulating a fatal
        /// (or transient) wait failure surfacing from the driver.
        var nextPollError: Kernel.Event.Driver.Error?
        /// Error the next arm throws (one-shot).
        var nextArmError: Kernel.Event.Driver.Error?
        /// Number of backend arm invocations.
        var armCount: Int = 0
    }

    struct Registration: Sendable, Equatable {
        let rawDescriptor: Int32
        var interest: Kernel.Event.Interest
    }

    // MARK: - Test Inspection API

    func registrations() -> [Kernel.Event.ID: Registration] {
        state.withLock { $0.registrations }
    }

    func registration(for id: Kernel.Event.ID) -> Registration? {
        state.withLock { $0.registrations[id] }
    }

    func isRegistered(_ id: Kernel.Event.ID) -> Bool {
        registration(for: id) != nil
    }

    func pushEvent(_ event: Kernel.Event) {
        state.withLock { $0.pendingEvents.append(event) }
    }

    func pushEvents(_ events: [Kernel.Event]) {
        state.withLock { $0.pendingEvents.append(contentsOf: events) }
    }

    func simulateShutdown() {
        state.withLock { $0.isShutdown = true }
    }

    /// Make the next poll throw the given driver error (one-shot).
    func failNextPoll(with error: Kernel.Event.Driver.Error) {
        state.withLock { $0.nextPollError = error }
    }

    /// Make the next arm throw the given driver error (one-shot).
    func failNextArm(with error: Kernel.Event.Driver.Error) {
        state.withLock { $0.nextArmError = error }
    }

    func armCount() -> Int {
        state.withLock { $0.armCount }
    }

    // MARK: - Backend Operations (called by Driver closures)

    func add(
        fd: borrowing Kernel.Descriptor,
        id: Kernel.Event.ID,
        interest: Kernel.Event.Interest
    ) throws(Kernel.Event.Driver.Error) {
        let rawFd = fd._rawValue
        var error: Kernel.Event.Driver.Error?
        state.withLock { state in
            guard !state.isShutdown else {
                error = .invalidDescriptor
                return
            }
            state.registrations[id] = Registration(rawDescriptor: rawFd, interest: interest)
        }
        if let error { throw error }
    }

    func modify(
        fd: borrowing Kernel.Descriptor,
        id: Kernel.Event.ID,
        old: Kernel.Event.Interest,
        new: Kernel.Event.Interest
    ) throws(Kernel.Event.Driver.Error) {
        var error: Kernel.Event.Driver.Error?
        state.withLock { state in
            guard !state.isShutdown else {
                error = .invalidDescriptor
                return
            }
            guard state.registrations[id] != nil else {
                error = .notRegistered
                return
            }
            state.registrations[id]?.interest = new
        }
        if let error { throw error }
    }

    func remove(
        fd: borrowing Kernel.Descriptor,
        id: Kernel.Event.ID
    ) throws(Kernel.Event.Driver.Error) {
        var error: Kernel.Event.Driver.Error?
        state.withLock { state in
            guard !state.isShutdown else {
                error = .invalidDescriptor
                return
            }
            _ = state.registrations.removeValue(forKey: id)
        }
        if let error { throw error }
    }

    func arm(
        fd: borrowing Kernel.Descriptor,
        id: Kernel.Event.ID,
        interest: Kernel.Event.Interest
    ) throws(Kernel.Event.Driver.Error) {
        var error: Kernel.Event.Driver.Error?
        state.withLock { state in
            state.armCount += 1
            guard !state.isShutdown else {
                error = .invalidDescriptor
                return
            }
            guard state.registrations[id] != nil else {
                error = .notRegistered
                return
            }
            if let next = state.nextArmError {
                state.nextArmError = nil
                error = next
            }
        }
        if let error { throw error }
    }

    func poll(into buffer: inout [Kernel.Event]) throws(Kernel.Event.Driver.Error) -> Int {
        var pollError: Kernel.Event.Driver.Error?
        let count = state.withLock { state -> Int in
            if let error = state.nextPollError {
                state.nextPollError = nil
                pollError = error
                return 0
            }
            if state.wakeupPending {
                state.wakeupPending = false
                return 0
            }
            let events = state.pendingEvents
            state.pendingEvents = []
            let count = min(events.count, buffer.count)
            for i in 0..<count { buffer[i] = events[i] }
            return count
        }
        if let pollError { throw pollError }
        return count
    }

    func close() {
        state.withLock { $0.isClosed = true }
    }
}
