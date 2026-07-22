//
//  IO.Event.Actor.Registration.Senders Tests.swift
//  swift-io
//


import Async
import Testing

@_spi(Syscall) @testable import IO_Events

extension Event.Actor.Registration.Senders {
    @Suite
    struct Test {
        @Suite struct Unit {}
        @Suite struct `Edge Case` {}
        @Suite struct Integration {}
    }
}

extension Event.Actor.Registration.Senders.Test.Unit {
    @Test
    func `remove closes only the exact sender and preserves ordered survivors`() async throws(Async.Channel<Kernel.Event>.Error) {
        var firstChannel = Async.Channel<Kernel.Event>.Unbounded()
        let firstSender = firstChannel.sender
        let firstEnds = (consume firstChannel).take().ends()
        var secondChannel = Async.Channel<Kernel.Event>.Unbounded()
        let secondSender = secondChannel.sender
        let secondEnds = (consume secondChannel).take().ends()
        var senders = Event.Actor.Registration.Senders()

        senders.append(firstSender, for: .read)
        senders.append(secondSender, for: .read)
        senders.remove(firstSender, for: .read)
        senders.remove(firstSender, for: .read)

        #expect(senders.read == [secondSender])
        let firstEvent = try await firstEnds.receiver.receive()
        #expect(firstEvent == nil)

        let expected = Kernel.Event(id: Event.ID(0), interest: .read, flags: [])
        senders.drain(event: expected, for: .read)

        let secondEvent = try await secondEnds.receiver.receive()
        #expect(secondEvent == expected)
        #expect(senders.read.isEmpty)
    }
}
