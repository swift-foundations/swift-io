import IO_Test_Support
@_spi(Syscall) import Kernel
import Testing

@testable import IO_Events

extension Event.Actor {
    @Suite
    struct `Edge Case` {}
}

extension Event.Actor.`Edge Case` {

    private enum Sink {
        nonisolated(unsafe) static var actors: [Event.Actor] = []
        nonisolated(unsafe) static let lock = Kernel.Thread.Mutex()

        static func retain(_ actor: Event.Actor) {
            lock.withLock { actors.append(actor) }
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `fatal poll error: actor leaves running and register fails fast`() async throws {
        let controller = Event.Fake.Controller()
        let actor = Event.Actor(source: Event.Fake.make(controller: controller))
        Sink.retain(actor)

        controller.failNextPoll(with: .invalidDescriptor)

        while await actor.state == .running {
            try await Task.sleep(for: .milliseconds(1))
        }

        let pipe = try Kernel.Pipe.pipe()
        await #expect(throws: Event.Failure.left(.shutdown)) {
            _ = try await actor.register(pipe.read)
        }
    }

    @Test(.timeLimit(.minutes(1)))
    func `fatal poll error: wait fails fast instead of hanging`() async throws {
        let controller = Event.Fake.Controller()
        let actor = Event.Actor(source: Event.Fake.make(controller: controller))
        Sink.retain(actor)

        controller.failNextPoll(with: .invalidDescriptor)
        while await actor.state == .running {
            try await Task.sleep(for: .milliseconds(1))
        }

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

    @Test(.timeLimit(.minutes(1)))
    func `explicit repeated shutdown rejects register and wait`() async throws {
        let controller = Event.Fake.Controller()
        let actor = Event.Actor(source: Event.Fake.make(controller: controller))
        Sink.retain(actor)

        await actor.shutdown()
        await actor.shutdown()

        let state = await actor.state
        #expect(state == .shuttingDown)
        let pipe = try Kernel.Pipe.pipe()
        await #expect(throws: Event.Failure.left(.shutdown)) {
            _ = try await actor.register(pipe.read)
        }
        await #expect(throws: Event.Failure.left(.shutdown)) {
            try await actor.wait(for: Event.ID(0), interest: .read)
        }
    }

    #if compiler(>=6.4)
        @Test(.timeLimit(.minutes(1)))
        func `arm failure propagates typed error and rolls back sender`() async throws {
            let controller = Event.Fake.Controller()
            let actor = Event.Actor(source: Event.Fake.make(controller: controller))
            let pipe = try Kernel.Pipe.pipe()
            let id = try await actor.register(pipe.read)
            controller.failNextArm(with: .invalidDescriptor)

            let failure: Event.Failure?
            do throws(Event.Failure) {
                try await actor.wait(for: id, interest: .read)
                failure = nil
            } catch {
                failure = error
            }

            #expect(failure == .right(.invalidDescriptor))
            #expect(controller.armCount() == 1)
            await actor.shutdown()
        }

        @Test(.timeLimit(.minutes(1)))
        func `cancelled wait removes only its sender and preserves a same-interest survivor`()
            async throws
        {
            let controller = Event.Fake.Controller()
            let actor = Event.Actor(source: Event.Fake.make(controller: controller))
            let pipe = try Kernel.Pipe.pipe()
            let id = try await actor.register(pipe.read)
            let cancelled = Task { () async -> Event.Failure? in
                do throws(Event.Failure) {
                    try await actor.wait(for: id, interest: .read)
                    return nil
                } catch {
                    return error
                }
            }
            while controller.armCount() < 1 {
                try await Task.sleep(for: .milliseconds(1))
            }
            let survivor = Task { () async -> Event.Failure? in
                do throws(Event.Failure) {
                    try await actor.wait(for: id, interest: .read)
                    return nil
                } catch {
                    return error
                }
            }
            while controller.armCount() < 2 {
                try await Task.sleep(for: .milliseconds(1))
            }

            cancelled.cancel()
            let cancelledFailure = await cancelled.value
            controller.pushEvent(Kernel.Event(id: id, interest: .read, flags: []))
            let survivorFailure = await survivor.value

            #expect(cancelledFailure == .left(.cancelled))
            #expect(survivorFailure == nil)
            await actor.shutdown()
        }

        @Test(.timeLimit(.minutes(1)))
        func `cancellation racing dispatch completes exactly once`() async throws {
            let controller = Event.Fake.Controller()
            let actor = Event.Actor(source: Event.Fake.make(controller: controller))
            let pipe = try Kernel.Pipe.pipe()
            let id = try await actor.register(pipe.read)
            let waiter = Task { () async -> Event.Failure? in
                do throws(Event.Failure) {
                    try await actor.wait(for: id, interest: .read)
                    return nil
                } catch {
                    return error
                }
            }
            while controller.armCount() < 1 {
                try await Task.sleep(for: .milliseconds(1))
            }

            controller.pushEvent(Kernel.Event(id: id, interest: .read, flags: []))
            waiter.cancel()
            let failure = await waiter.value

            #expect(failure == nil || failure == .left(.cancelled))
            await actor.shutdown()
        }

        @Test(.timeLimit(.minutes(1)))
        func `cancellation racing shutdown closes waiter and clears tables`() async throws {
            let controller = Event.Fake.Controller()
            let actor = Event.Actor(source: Event.Fake.make(controller: controller))
            let pipe = try Kernel.Pipe.pipe()
            let id = try await actor.register(pipe.read)
            let waiter = Task { () async -> Event.Failure? in
                do throws(Event.Failure) {
                    try await actor.wait(for: id, interest: .read)
                    return nil
                } catch {
                    return error
                }
            }
            while controller.armCount() < 1 {
                try await Task.sleep(for: .milliseconds(1))
            }

            waiter.cancel()
            await actor.shutdown()
            let failure = await waiter.value

            #expect(failure == .left(.cancelled) || failure == .left(.shutdown))
            let state = await actor.state
            #expect(state == .shuttingDown)
        }
    #endif
}
