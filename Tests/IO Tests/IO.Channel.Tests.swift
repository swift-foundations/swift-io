import IO
import Testing

private enum ChannelFailure: Swift.Error, Sendable, Equatable {
    case stopped(Int)
}

@Suite
struct `IO Channel Tests` {
    @Test
    func `pair transports in both directions and preserves half close drain`() async throws(IO
        .Channel<Int, ChannelFailure>.Error)
    {
        var (left, right) = IO.Channel<Int, ChannelFailure>.pair(capacity: 2)

        try await left.outbound.send(1)
        try await right.outbound.send(2)
        left.outbound.finish()

        #expect(try await right.inbound.receive() == 1)
        #expect(try await left.inbound.receive() == 2)
        #expect(try await right.inbound.receive() == nil)
    }

    @Test
    func `directional failure crosses only its owning direction`() async throws(IO.Channel<
        Int, ChannelFailure
    >.Error) {
        var (left, right) = IO.Channel<Int, ChannelFailure>.pair(capacity: 2)

        try await left.outbound.send(1)
        left.outbound.fail(.stopped(2))

        #expect(try await right.inbound.receive() == 1)
        do throws(IO.Channel<Int, ChannelFailure>.Error) {
            _ = try await right.inbound.receive()
            Issue.record("Expected the outbound failure after the buffered drain")
        } catch {
            switch error {
            case .failed(.stopped(2)):
                break

            default:
                Issue.record("Expected the declared outbound failure")
            }
        }

        try await right.outbound.send(3)
        #expect(try await left.inbound.receive() == 3)
    }

    @Test
    func `reader failure resumes a backpressured writer with the exact failure`() async throws(IO
        .Channel<Int, ChannelFailure>.Error)
    {
        var (left, right) = IO.Channel<Int, ChannelFailure>.pair(capacity: 1)
        let writer = left.outbound

        try await writer.send(1)
        let blocked = Task { () -> IO.Channel<Int, ChannelFailure>.Error? in
            do throws(IO.Channel<Int, ChannelFailure>.Error) {
                try await writer.send(2)
                return nil
            } catch {
                return error
            }
        }

        await Task.yield()
        right.inbound.fail(.stopped(4))
        switch await blocked.value {
        case .some(.failed(.stopped(4))):
            break

        default:
            Issue.record("Expected the declared reader failure")
        }
    }

    @Test
    func `shutdown closes inbound before outbound without changing typed endpoint laws`()
        async throws(IO.Channel<Int, ChannelFailure>.Error)
    {
        var (left, right) = IO.Channel<Int, ChannelFailure>.pair(capacity: 1)

        left.shutdown()

        do throws(IO.Channel<Int, ChannelFailure>.Error) {
            try await right.outbound.send(1)
            Issue.record("Expected shutdown's inbound close to reject peer sends")
        } catch {
            switch error {
            case .finished:
                break

            default:
                Issue.record("Expected shutdown's inbound close to finish the peer writer")
            }
        }
        #expect(try await right.inbound.receive() == nil)
    }

    @Test
    func `byte channel fixes each element to the canonical buffer slice`() {
        let _: IO.Byte.Channel<ChannelFailure>.Type = IO.Byte.Channel<ChannelFailure>.self
    }
}
