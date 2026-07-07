//
//  Event.Driver.Contract.Tests.swift
//  swift-io
//
//  Tests for the event source contract using the Fake.
//

import IO_Test_Support
@_spi(Syscall) import Kernel
import Testing

@testable import IO_Events

@Suite(
    "Event.Source.Contract",
    .disabled(
        if: Toolchain.hasTaggedMetadataSIGSEGV,
        "catalog §A9: Tagged<Kernel.Event> registry key forces the institute __Dictionary/__HashIndexed metadata; swift_getTypeByMangledName null-deref SIGSEGV at Driver.init insert on compiler(<6.4). Fixed on Swift 6.4+. See swift-institute/Issues/swift-issue-tagged-dictionary-insert-metadata-crash."
    )
)
struct SourceContractTests {

    // MARK: - Registration Contract

    @Test
    func `register creates valid ID and stores mapping`() throws {
        let controller = Event.Fake.Controller()
        var source = Event.Fake.make(controller: controller)

        let id = try source.register(descriptor: Kernel.Descriptor(_rawValue: -42), interest: .read)

        let registration = controller.registration(for: id)
        #expect(registration != nil)
        #expect(registration?.rawDescriptor == -42)
        #expect(registration?.interest == .read)
    }

    @Test
    func `register with multiple interests stores all`() throws {
        let controller = Event.Fake.Controller()
        var source = Event.Fake.make(controller: controller)

        let id = try source.register(descriptor: Kernel.Descriptor(_rawValue: -10), interest: [.read, .write])

        let registration = controller.registration(for: id)
        #expect(registration?.interest.contains(.read) == true)
        #expect(registration?.interest.contains(.write) == true)
    }

    @Test
    func `register generates unique IDs`() throws {
        let controller = Event.Fake.Controller()
        var source = Event.Fake.make(controller: controller)

        let id1 = try source.register(descriptor: Kernel.Descriptor(_rawValue: -1), interest: .read)
        let id2 = try source.register(descriptor: Kernel.Descriptor(_rawValue: -2), interest: .read)
        let id3 = try source.register(descriptor: Kernel.Descriptor(_rawValue: -3), interest: .read)

        #expect(id1 != id2)
        #expect(id2 != id3)
        #expect(id1 != id3)
    }

    // MARK: - Modify Contract

    @Test
    func `modify updates interest correctly`() throws {
        let controller = Event.Fake.Controller()
        var source = Event.Fake.make(controller: controller)

        let id = try source.register(descriptor: Kernel.Descriptor(_rawValue: -42), interest: .read)
        try source.modify(id: id, interest: .write)

        let registration = controller.registration(for: id)
        #expect(registration?.interest == .write)
    }

    @Test
    func `modify can add interests`() throws {
        let controller = Event.Fake.Controller()
        var source = Event.Fake.make(controller: controller)

        let id = try source.register(descriptor: Kernel.Descriptor(_rawValue: -42), interest: .read)
        try source.modify(id: id, interest: [.read, .write])

        let registration = controller.registration(for: id)
        #expect(registration?.interest.contains(.read) == true)
        #expect(registration?.interest.contains(.write) == true)
    }

    @Test
    func `modify can remove interests`() throws {
        let controller = Event.Fake.Controller()
        var source = Event.Fake.make(controller: controller)

        let id = try source.register(descriptor: Kernel.Descriptor(_rawValue: -42), interest: [.read, .write])
        try source.modify(id: id, interest: .read)

        let registration = controller.registration(for: id)
        #expect(registration?.interest == .read)
    }

    @Test
    func `modify on unregistered ID throws notRegistered`() throws {
        let controller = Event.Fake.Controller()
        var source = Event.Fake.make(controller: controller)

        let fakeID = Event.ID(999)

        #expect(throws: Kernel.Event.Driver.Error.notRegistered) {
            try source.modify(id: fakeID, interest: .write)
        }
    }

    // MARK: - Deregister Contract

    @Test
    func `deregister removes registration`() throws {
        let controller = Event.Fake.Controller()
        var source = Event.Fake.make(controller: controller)

        let id = try source.register(descriptor: Kernel.Descriptor(_rawValue: -42), interest: .read)
        #expect(controller.isRegistered(id) == true)

        try source.deregister(id: id)
        #expect(controller.isRegistered(id) == false)
    }

    @Test
    func `deregister is idempotent`() throws {
        let controller = Event.Fake.Controller()
        var source = Event.Fake.make(controller: controller)

        let id = try source.register(descriptor: Kernel.Descriptor(_rawValue: -42), interest: .read)
        try source.deregister(id: id)
        try source.deregister(id: id)  // Should not throw

        #expect(controller.isRegistered(id) == false)
    }

    @Test
    func `deregister on never-registered ID succeeds`() throws {
        let controller = Event.Fake.Controller()
        var source = Event.Fake.make(controller: controller)

        let fakeID = Event.ID(999)
        try source.deregister(id: fakeID)  // Should not throw
    }

    // MARK: - Poll Race Rule

    @Test
    func `poll drops events for deregistered IDs`() throws {
        let controller = Event.Fake.Controller()
        var source = Event.Fake.make(controller: controller)

        let id = try source.register(descriptor: Kernel.Descriptor(_rawValue: -42), interest: .read)

        // Push event, then deregister before poll
        controller.pushEvent(Kernel.Event(id: id, interest: .read, flags: []))
        try source.deregister(id: id)

        // Poll should return 0 events (staleness suppression filters deregistered IDs)
        // Deliberate: [Kernel.Event](repeating:count:) parses ambiguously against
        // ISO_9945.Kernel.Event on Ubuntu release builds (b3c5b86e); the fully-qualified
        // Swift.Array<Kernel.Event> form removes the ambiguity and must stay explicit.
        // swiftlint:disable:next syntactic_sugar
        var buffer = Swift.Array<Kernel.Event>(repeating: .empty, count: 10)
        let count = try source.poll(deadline: nil, into: &buffer)
        #expect(count == 0)
    }

    @Test
    func `poll returns events for registered IDs`() throws {
        let controller = Event.Fake.Controller()
        var source = Event.Fake.make(controller: controller)

        let id = try source.register(descriptor: Kernel.Descriptor(_rawValue: -42), interest: .read)

        controller.pushEvent(Kernel.Event(id: id, interest: .read, flags: []))

        // Deliberate: [Kernel.Event](repeating:count:) parses ambiguously against
        // ISO_9945.Kernel.Event on Ubuntu release builds (b3c5b86e); the fully-qualified
        // Swift.Array<Kernel.Event> form removes the ambiguity and must stay explicit.
        // swiftlint:disable:next syntactic_sugar
        var buffer = Swift.Array<Kernel.Event>(repeating: .empty, count: 10)
        let count = try source.poll(deadline: nil, into: &buffer)
        #expect(count == 1)
        #expect(buffer[0].id == id)
        #expect(buffer[0].interest == .read)
    }

    @Test
    func `poll returns multiple events in order`() throws {
        let controller = Event.Fake.Controller()
        var source = Event.Fake.make(controller: controller)

        let id1 = try source.register(descriptor: Kernel.Descriptor(_rawValue: -1), interest: .read)
        let id2 = try source.register(descriptor: Kernel.Descriptor(_rawValue: -2), interest: .write)

        controller.pushEvents([
            Kernel.Event(id: id1, interest: .read, flags: []),
            Kernel.Event(id: id2, interest: .write, flags: []),
        ])

        // Deliberate: [Kernel.Event](repeating:count:) parses ambiguously against
        // ISO_9945.Kernel.Event on Ubuntu release builds (b3c5b86e); the fully-qualified
        // Swift.Array<Kernel.Event> form removes the ambiguity and must stay explicit.
        // swiftlint:disable:next syntactic_sugar
        var buffer = Swift.Array<Kernel.Event>(repeating: .empty, count: 10)
        let count = try source.poll(deadline: nil, into: &buffer)
        #expect(count == 2)
        #expect(buffer[0].id == id1)
        #expect(buffer[1].id == id2)
    }

    // MARK: - Wakeup

    @Test
    func `wakeup causes poll to return immediately`() throws {
        let controller = Event.Fake.Controller()
        var source = Event.Fake.make(controller: controller)
        let wakeup = source.wakeup

        wakeup.wake()

        // Deliberate: [Kernel.Event](repeating:count:) parses ambiguously against
        // ISO_9945.Kernel.Event on Ubuntu release builds (b3c5b86e); the fully-qualified
        // Swift.Array<Kernel.Event> form removes the ambiguity and must stay explicit.
        // swiftlint:disable:next syntactic_sugar
        var buffer = Swift.Array<Kernel.Event>(repeating: .empty, count: 10)
        let count = try source.poll(deadline: nil, into: &buffer)
        #expect(count == 0)  // Wakeup returns 0 events
    }

    // MARK: - Close

    @Test
    func `close cleans up state`() throws {
        let controller = Event.Fake.Controller()
        var source = Event.Fake.make(controller: controller)
        _ = try source.register(descriptor: Kernel.Descriptor(_rawValue: -42), interest: .read)

        source.close()

        // Controller should have received the close call
    }

    // MARK: - Shutdown Simulation

    @Test
    func `simulated shutdown rejects new registrations`() throws {
        let controller = Event.Fake.Controller()
        var source = Event.Fake.make(controller: controller)

        controller.simulateShutdown()

        #expect(throws: Kernel.Event.Driver.Error.self) {
            try source.register(descriptor: Kernel.Descriptor(_rawValue: -42), interest: .read)
        }
    }

    @Test
    func `simulated shutdown rejects modify`() throws {
        let controller = Event.Fake.Controller()
        var source = Event.Fake.make(controller: controller)
        let id = try source.register(descriptor: Kernel.Descriptor(_rawValue: -42), interest: .read)

        controller.simulateShutdown()

        #expect(throws: Kernel.Event.Driver.Error.self) {
            try source.modify(id: id, interest: .write)
        }
    }
}

// MARK: - Empty Event Helper

extension Kernel.Event {
    /// Empty event for buffer initialization.
    static var empty: Kernel.Event {
        Kernel.Event(id: Event.ID(0), interest: [], flags: [])
    }
}
