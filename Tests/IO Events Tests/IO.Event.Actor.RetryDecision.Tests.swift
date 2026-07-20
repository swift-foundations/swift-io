//
//  Event.Actor.RetryDecision.Tests.swift
//  swift-io
//
//  Unit tests for the wait-failure classification used by the Actor's
//  tick closure. Verifies the EINTR / ENOMEM / EAGAIN / fatal mapping.
//

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

    // MARK: - Transient errors retry

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
    func `EAGAIN is classified as retry (Linux value 11)`() {
        let decision = Event.Actor.RetryDecision(
            for: .platform(.posix(Int32(11)))
        )
        #expect(decision == .retry)
    }

    @Test
    func `EAGAIN is classified as retry (Darwin value 35)`() {
        // Darwin: EAGAIN == 35; on Linux posix(35) is EUCLEAN (fatal).
        let decision = Event.Actor.RetryDecision(
            for: .platform(.posix(Int32(35)))
        )
        #expect(decision == .retry)
    }

    // MARK: - Fatal errors halt

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
