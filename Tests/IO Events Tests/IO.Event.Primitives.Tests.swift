//
//  Event.Primitives.Tests.swift
//  swift-io
//
//  Created by Coen ten Thije Boonkkamp on 28/12/2025.
//

import IO_Events
import IO_Test_Support
import Kernel
import Testing

@Suite(.timeLimit(.minutes(1)))
struct `Event Primitives` {

    @Test
    func `Interest OptionSet operations`() {
        let read: Event.Interest = .read
        let write: Event.Interest = .write
        let both: Event.Interest = [.read, .write]

        #expect(both.contains(.read))
        #expect(both.contains(.write))
        #expect(!read.contains(.write))
        #expect(read.union(write) == both)
    }

    @Test
    func `Event creation and properties`() {
        let id = Event.ID(42)
        let event = Kernel.Event(
            id: id,
            interest: [.read, .write],
            flags: [.hangup]
        )

        #expect(event.id == id)
        #expect(event.interest.contains(.read))
        #expect(event.interest.contains(.write))
        #expect(event.flags.contains(.hangup))
        #expect(!event.flags.contains(.error))
    }

    @Test
    func `Event.Options combinations`() {
        let flags: Event.Options = [.error, .hangup]

        #expect(flags.contains(.error))
        #expect(flags.contains(.hangup))
        #expect(!flags.contains(.readHangup))
    }

    @Test
    func `ID equality and hashing`() {
        let id1 = Event.ID(100)
        let id2 = Event.ID(100)
        let id3 = Event.ID(200)

        #expect(id1 == id2)
        #expect(id1 != id3)
        #expect(id1.hashValue == id2.hashValue)
    }

    @Test
    func `Token creation and ID access`() {
        let _ = Event.ID(42)
        // Tokens are created internally, but we can test the type exists
        // and the ID is accessible via consuming operations
    }

    @Test
    func `Error descriptions`() {
        let platformError = Event.Error.platform(.posix(22))
        let invalidDesc = Event.Error.invalidDescriptor
        let writeClosed = Event.Error.writeClosed

        #expect(platformError.description.contains("Platform"))
        #expect(invalidDesc.description.contains("Invalid"))
        #expect(writeClosed.description.contains("closed"))
    }
}
