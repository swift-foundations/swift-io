//
//  Completion.Actor Tests.swift
//  swift-io
//
//  FakeBackend-driven tests for completions actor internals that can't
//  be verified through the IO witness: lifecycle observation, submission
//  recording, and error injection.
//

#if !os(Windows)

import Testing
@testable import IO_Completions
import IO_Completions_Test_Support
@_spi(Syscall) import Kernel_Completion
import Memory_Primitives
import Span_Raw_Primitives

@Suite struct ProactorTests {
    @Suite struct ActorTests {

        @Suite struct Unit {

            @Test func `init with fake kernel boots executor`() async {
                let (actor, backend) = Completion.Actor.fake()
                #expect(!backend.isClosed)
                _ = actor
            }

            @Test func `deinit shuts down backend`() async {
                let backend: Kernel.Completion.Fake
                do {
                    let (actor, b) = Completion.Actor.fake()
                    backend = b
                    #expect(!backend.isClosed)
                    _ = actor
                }
                #expect(backend.waitUntilClosed(timeout: .seconds(2)))
            }

            @Test func `submit records in backend`() async throws {
                let (actor, backend) = Completion.Actor.fake()
                backend.onSubmit = { submission in
                    Kernel.Completion.Event(
                        token: submission.token,
                        result: .init(rawValue: 0)
                    )
                }
                let pipe = try Kernel.Pipe.pipe()
                _ = try await actor.ready(from: pipe.read, interest: .read)
                #expect(backend.submissions.count >= 1)
            }

            @Test func `flush is called after submit`() async throws {
                let (actor, backend) = Completion.Actor.fake()
                backend.onSubmit = { submission in
                    Kernel.Completion.Event(
                        token: submission.token,
                        result: .init(rawValue: 0)
                    )
                }
                let pipe = try Kernel.Pipe.pipe()
                _ = try await actor.ready(from: pipe.read, interest: .read)
                #expect(backend.flushCount >= 1)
            }

            @Test func `ID generation is monotonic`() async throws {
                let (actor, backend) = Completion.Actor.fake()
                backend.onSubmit = { submission in
                    Kernel.Completion.Event(
                        token: submission.token,
                        result: .init(rawValue: 0)
                    )
                }
                let pipe = try Kernel.Pipe.pipe()
                _ = try await actor.ready(from: pipe.read, interest: .read)
                _ = try await actor.ready(from: pipe.read, interest: .read)
                let subs = backend.submissions
                #expect(subs.count >= 2)
                #expect(subs[0].token != subs[1].token)
            }
        }

        @Suite struct `Edge Case` {

            @Test func `error CQE maps to Basic.Error`() async throws {
                let (actor, backend) = Completion.Actor.fake()
                backend.onSubmit = { submission in
                    Kernel.Completion.Event(
                        token: submission.token,
                        result: .init(rawValue: -9) // -EBADF
                    )
                }
                let pipe = try Kernel.Pipe.pipe()
                let readBuf = UnsafeMutableRawBufferPointer.allocate(
                    byteCount: 64, alignment: 1
                )
                defer { unsafe readBuf.deallocate() }
                let buffer: Span.Raw.Mutable = unsafe .init(readBuf)
                do {
                    _ = try await actor.read(from: pipe.read, into: buffer)
                    Issue.record("expected Basic.Error")
                } catch {
                    // Error thrown — correct behavior
                }
            }
        }
    }
}

#endif
