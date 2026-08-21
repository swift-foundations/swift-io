import Kernel
import Testing

@testable import IO_Events

extension Event.Actor.RetryDecision {
    @Suite
    struct Test {
        @Suite struct Unit {}
    }
}

extension Event.Actor.RetryDecision.Test.Unit {

    @Test
    func `EINTR is classified as retry`() {
        let decision = Event.Actor.RetryDecision(
            for: .platform(.POSIX.EINTR)
        )
        #expect(decision == .retry)
    }

    @Test
    func `ENOMEM yields before retry`() {
        let decision = Event.Actor.RetryDecision(
            for: .platform(.POSIX.ENOMEM)
        )
        #expect(decision == .yieldAndRetry)
    }

    @Test
    func `EAGAIN is classified as retry`() {
        let decision = Event.Actor.RetryDecision(
            for: .platform(.POSIX.EAGAIN)
        )
        #expect(decision == .retry)
    }

    @Test
    func `Unknown platform code halts`() {
        let decision = Event.Actor.RetryDecision(
            for: .platform(.posix(Int32(62)))
        )
        #expect(decision == .halt)
    }

    @Test
    func `invalidDescriptor halts`() {
        let decision = Event.Actor.RetryDecision(for: .invalidDescriptor)
        #expect(decision == .halt)
    }

    @Test
    func `notRegistered halts`() {
        let decision = Event.Actor.RetryDecision(for: .notRegistered)
        #expect(decision == .halt)
    }
}
